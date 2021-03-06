#!/usr/bin/env perl
#
# new_table - perl script for mySQL partition rotation
#
# Copyright (C) 2011-2016 Alexandr Dubovikov (alexandr.dubovikov@gmail.com)
#
# This file is part of webhomer, a free capture server.
#
# partrotate_unixtimestamp is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version
#
# partrotate_unixtimestamp is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

use 5.010;
use strict;
use warnings;
use DBI;
use POSIX;

my $version = "1.2.0";
$| =1;

# Determine path and set default rotation.ini location
my $script_location = `dirname $0`;
$script_location =~ s/^\s+|\s+$//g;
my $default_ini = $script_location."/rotation.ini";

my $conf_file = $ARGV[0] // $default_ini;

my @stepsvalues = (86400, 3600, 1800, 900);
my $msgsize = 1400;
our $CONFIG = read_config($conf_file);

# Optionally load override configuration. perl format
my $rc = "/etc/sysconfig/partrotaterc";
if (-e $rc) {
    do $rc;
}

my $newtables = $CONFIG->{"PGSQL"}{"newtables"};
my $tablespace = $CONFIG->{"PGSQL"}{"tablespace"};

if($CONFIG->{"SYSTEM"}{"debug"} == 1) {
    #Debug only
    foreach my $section (sort keys %{$CONFIG}) {
        foreach my $value (keys %{ $CONFIG->{$section} }) {
            say "$section, $value: $CONFIG->{$section}{$value}";
        }
    }
}

my $ORIGINAL_DATA_TABLE=<<END;
CREATE TABLE IF NOT EXISTS [TRANSACTION]_[TIMESTAMP] (
  id BIGSERIAL NOT NULL,
  date timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
  micro_ts bigint NOT NULL DEFAULT '0',
  method varchar(50) NOT NULL DEFAULT '',
  reply_reason varchar(100) NOT NULL DEFAULT '',
  ruri varchar(200) NOT NULL DEFAULT '',
  ruri_user varchar(100) NOT NULL DEFAULT '',
  ruri_domain varchar(150) NOT NULL DEFAULT '',
  from_user varchar(100) NOT NULL DEFAULT '',
  from_domain varchar(150) NOT NULL DEFAULT '',
  from_tag varchar(64) NOT NULL DEFAULT '',
  to_user varchar(100) NOT NULL DEFAULT '',
  to_domain varchar(150) NOT NULL DEFAULT '',
  to_tag varchar(64) NOT NULL DEFAULT '',
  pid_user varchar(100) NOT NULL DEFAULT '',
  contact_user varchar(120) NOT NULL DEFAULT '',
  auth_user varchar(120) NOT NULL DEFAULT '',
  callid varchar(120) NOT NULL DEFAULT '',
  callid_aleg varchar(120) NOT NULL DEFAULT '',
  via_1 varchar(256) NOT NULL DEFAULT '',
  via_1_branch varchar(80) NOT NULL DEFAULT '',
  cseq varchar(25) NOT NULL DEFAULT '',
  diversion varchar(256) NOT NULL DEFAULT '',
  reason varchar(200) NOT NULL DEFAULT '',
  content_type varchar(256) NOT NULL DEFAULT '',
  auth varchar(256) NOT NULL DEFAULT '',
  user_agent varchar(256) NOT NULL DEFAULT '',
  source_ip varchar(60) NOT NULL DEFAULT '',
  source_port integer NOT NULL DEFAULT 0,
  destination_ip varchar(60) NOT NULL DEFAULT '',
  destination_port integer NOT NULL DEFAULT 0,
  contact_ip varchar(60) NOT NULL DEFAULT '',
  contact_port integer NOT NULL DEFAULT 0,
  originator_ip varchar(60) NOT NULL DEFAULT '',
  originator_port integer NOT NULL DEFAULT 0,
  expires integer NOT NULL DEFAULT '-1',
  correlation_id varchar(256) NOT NULL DEFAULT '',
  custom_field1 varchar(120) NOT NULL DEFAULT '',
  custom_field2 varchar(120) NOT NULL DEFAULT '',
  custom_field3 varchar(120) NOT NULL DEFAULT '',
  proto integer NOT NULL DEFAULT 0,
  family smallint DEFAULT NULL,
  rtp_stat varchar(256) NOT NULL DEFAULT '',
  type integer NOT NULL DEFAULT 0,
  node varchar(125) NOT NULL DEFAULT '',
  msg bytea NOT NULL DEFAULT '',
  PRIMARY KEY (id,date)
);

CREATE INDEX [TRANSACTION]_[TIMESTAMP]_ruri_user ON "[TRANSACTION]_[TIMESTAMP]" (ruri_user);
CREATE INDEX [TRANSACTION]_[TIMESTAMP]_from_user ON "[TRANSACTION]_[TIMESTAMP]" (from_user);
CREATE INDEX [TRANSACTION]_[TIMESTAMP]_to_user ON "[TRANSACTION]_[TIMESTAMP]" (to_user);
CREATE INDEX [TRANSACTION]_[TIMESTAMP]_pid_user ON "[TRANSACTION]_[TIMESTAMP]" (pid_user);
CREATE INDEX [TRANSACTION]_[TIMESTAMP]_auth_user ON "[TRANSACTION]_[TIMESTAMP]" (auth_user);
CREATE INDEX [TRANSACTION]_[TIMESTAMP]_callid_aleg ON "[TRANSACTION]_[TIMESTAMP]" (callid_aleg);
CREATE INDEX [TRANSACTION]_[TIMESTAMP]_date ON "[TRANSACTION]_[TIMESTAMP]" (date);
CREATE INDEX [TRANSACTION]_[TIMESTAMP]_callid ON "[TRANSACTION]_[TIMESTAMP]" (callid);

[PARTITIONS]

END

#Check DATA tables
my $db = db_connect($CONFIG, "db_data");
my $maxparts = 1;
my $newparts = 1;
    
foreach my $table (keys %{ $CONFIG->{"DATA_TABLE_ROTATION"} }) {

    my $rotate = $CONFIG->{'DATA_TABLE_ROTATION'}{$table};
    my $partstep = $CONFIG->{'DATA_TABLE_STEP'}{$table};
    $newparts = $CONFIG->{'PGSQL'}{'newtables'};
    $maxparts = $CONFIG->{'DATA_TABLE_ROTATION'}{$table} + $newparts;

    $partstep = 0 if(!defined $stepsvalues[$partstep]);
    my $mystep = $stepsvalues[$partstep];

    my @names = $db->tables;

    #SIP Data tables
    if($table=~/^sip_/) {
        my $curtstamp;
        for(my $y=0; $y<($newtables+1); $y++) {
            $curtstamp = time()+(86400*$y);
            new_data_table($curtstamp, $mystep, $partstep, $ORIGINAL_DATA_TABLE, $table);
        }

        #And remove
        say "Now removing old tables" if($CONFIG->{"SYSTEM"}{"debug"} == 1);
        my $rotation_horizon = $CONFIG->{"DATA_TABLE_ROTATION"}{$table};
        my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = gmtime(time() - 86400*$rotation_horizon);
        my $oldest = sprintf("%04d%02d%02d",($year+=1900),(++$mon),$mday,$hour);                        
        $oldest+=0;        
        my @tables = $db->tables( '', '', $table.'_%', '', {noprefix => 1} );
        
        foreach my $table_name (@tables)
        {
        
           $table_name=~s/^public\.//ig;
           #Skip partition's tables
           next if($table_name=~/_p[0-9]{10}$/);           
           my($proto, $cap, $type, $ts) = split(/_/, $table_name, 4);
           $ts+=0;
           if($ts < $oldest) {
               say "Removing table: $table_name" if($CONFIG->{"SYSTEM"}{"debug"} == 1);
               my $drop = "DROP TABLE $table_name CASCADE;";
               my $drh = $db->prepare($drop);
               $drh->execute();
           } else {
               say "Table $table_name is too young, leaving." if($CONFIG->{"SYSTEM"}{"debug"} == 1);
           }
        }
    }
    #Rtcp, Logs, Reports tables
    else {
        my $coof = int(86400/$mystep);
        #How much partitions
        $maxparts *= $coof;
        $newparts *= $coof;
        #Now
        new_partition_table($db, $CONFIG->{"PGSQL"}{"db_data"}, $table, $mystep, $partstep, $maxparts, $newparts);
    }
}


#Check STATS tables
$db = db_connect($CONFIG, "db_stats");

$maxparts = 1;
$newparts = 1;
foreach my $table (keys %{ $CONFIG->{"STATS_TABLE_ROTATION"} }) {

    $newparts = $CONFIG->{'PGSQL'}{'newtables'};
    $maxparts = $CONFIG->{'STATS_TABLE_ROTATION'}{$table} + $newparts;
    my $partstep = $CONFIG->{'STATS_TABLE_STEP'}{$table};

    #Check it
    $partstep = 0 unless(defined $stepsvalues[$partstep]);
    #Mystep
    my $mystep = $stepsvalues[$partstep];

    my $coof=int(86400/$mystep);
    #How much partitions
    $maxparts*=$coof;
    $newparts*=$coof;
    #$totalparts = ($maxparts+$newparts);
    new_partition_table($db, $CONFIG->{"PGSQL"}{"db_stats"}, $table, $mystep, $partstep, $maxparts, $newparts);
}

exit;

sub db_connect {
    my $CONFIG  = shift;
    my $db_name = shift;

    my $db = DBI->connect("dbi:Pg:dbname=".$CONFIG->{"PGSQL"}{$db_name}.";host=".$CONFIG->{"PGSQL"}{"host"}.";port=".$CONFIG->{"PGSQL"}{"port"}, $CONFIG->{"PGSQL"}{"user"}, $CONFIG->{"PGSQL"}{"password"});
    $db->do("SET default_tablespace = ".$tablespace) or printf(STDERR "Failed to set default namespace with error: %s", $db->errstr) if($CONFIG->{"SYSTEM"}{"exec"} == 1);
    return $db;

}

sub calculate_gmt_offset {
	my $timestamp = shift;
	my @utc = gmtime($timestamp);
	my @local = localtime($timestamp);
	my $timezone_offset = mktime(@local) - mktime(@utc);
	return $timezone_offset;
}

sub new_data_table {

    my $cstamp = shift;
    my $mystep = shift;
    my $partstep = shift;
    my $sqltable = shift;
    my $table = shift;

    my $newparts=int(86400/$mystep);

    my @partsadd;
    my $tz_offset = calculate_gmt_offset($cstamp);
    my ($sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst) = gmtime($cstamp);
    # mktime generates timestamp based on local timestamps, so we have to add our timezone offset
    my $kstamp = mktime (0+$tz_offset, 0, 0, $mday, $mon, $year, $wday, $yday, $isdst);

    my $table_timestamp = sprintf("%04d%02d%02d",($year+=1900),(++$mon),$mday);
    $sqltable=~s/\[TIMESTAMP\]/$table_timestamp/ig;

    # < condition
    for(my $i=0; $i<$newparts; $i++) {
        my $oldstamp = $kstamp;
        $kstamp+=$mystep;
        my ($sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst) = gmtime($oldstamp);

        my $newpartname = sprintf("p%04d%02d%02d%02d",($year+=1900),(++$mon),$mday,$hour);
        $newpartname.= sprintf("%02d", $min) if($partstep > 1);
        
        my $query = "CREATE TABLE ".$table."_".$table_timestamp."_".$newpartname."() INHERITS (".$table."_".$table_timestamp.")";
        push(@partsadd,$query);
        $query = "ALTER TABLE ".$table."_".$table_timestamp."_".$newpartname." ADD CONSTRAINT chk_".$table."_".$table_timestamp."_".$newpartname." CHECK (date < to_timestamp(".$kstamp."))";
        push(@partsadd,$query);
    }

    my $parts_count=scalar @partsadd;
    if($parts_count > 0)
    {
        my $val = join(';'."\n", @partsadd).";";
        $sqltable=~s/\[PARTITIONS\]/$val/ig;
        $sqltable=~s/\[TRANSACTION\]/$table/ig;
        $db->do($sqltable) or printf(STDERR "Failed to execute query [%s] with error: %s", $sqltable,$db->errstr) if($CONFIG->{"SYSTEM"}{"exec"} == 1);
        say "create data table: $sqltable" if($CONFIG->{"SYSTEM"}{"debug"} == 1);
    }
}

sub new_partition_table {

    my $db       = shift;
    my $db_name  = shift;
    my $table    = shift;
    my $mystep   = shift;
    my $partstep = shift;
    my $maxparts = shift;
    my $newparts = shift;

    my $part_key = "date";
    #Name of part key
    if( $table =~/alarm_/) {
        $part_key = "create_date";
    }
    elsif( $table =~/stats_/) {
        $part_key = "from_date";
    }

    my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = gmtime();
    my $curtstamp = time() - $sec - 60 * $min - 3600 * $hour;
    my ($sec1,$min1,$hour1,$mday1,$mon1,$year1,$wday1,$yday1,$isdst1) = gmtime($curtstamp);        
    my $limitpartname = sprintf("%04d%02d%02d%02d",($year1+=1900),(++$mon1),$mday1,$hour1);

    my %PARTS;    
    my @oldparts;
    my @partsremove;
    my @partsadd;
    
    my @tables = $db->tables( '', '', $table.'_%_p%', '', {noprefix => 1} );
    
    foreach my $table_name (@tables)
    {
    
         $table_name=~s/^public\.//ig;
         #Skip partition's tables
         next if($table_name!~/_p[0-9]{10}$/);           
         my($proto, $cap, $type, $ts, $minpart) = split(/_/, $table_name, 5);

         my $procstamp = $minpart;
         $procstamp=~s/^p//ig;         
         $procstamp+=0;
    
         if($limitpartname <= $procstamp) {
             $PARTS{$minpart."_".$procstamp} = 1;
        }
        else {
            push(@oldparts, $table_name);
        }
    }

    my $partcount = $#oldparts;
    my $minpart;
    if($partcount > $maxparts) {
        foreach my $ref (@oldparts) {
            push(@partsremove, $ref);
            $partcount--;
            last if($partcount <= $maxparts);
        }
    }

    #Delete all partitions
    foreach my $table_drop (@partsremove)
    {             
        my $query = "DROP TABLE ".$table_drop;
        say "DROP Partition: [$query]" if($CONFIG->{"SYSTEM"}{"debug"} == 1);
        $db->do($query) or printf(STDERR "Failed to execute query [%s] with error: %s\n", ,$db->errstr) if($CONFIG->{"SYSTEM"}{"exec"} == 1);
        if (!$db->{Executed}) {
            say "Couldn't drop partition: $minpart";
            break;
        }
    }

    say "Newparts: $newparts" if($CONFIG->{"SYSTEM"}{"debug"} == 1);

    # < condition
    $curtstamp+=(86400);
    my $stopstamp = time() + (86400*$newtables);

    for(my $i=0; $i<$newparts; $i++) {
        my $oldstamp = $curtstamp;
        $curtstamp+=$mystep;
        my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = gmtime($oldstamp);
        my $newpartname = sprintf("p%04d%02d%02d%02d",($year+=1900),(++$mon),$mday,$hour);
        $newpartname.= sprintf("%02d", $min) if($partstep > 1);
        
        if(!defined $PARTS{$newpartname."_".$curtstamp}) {
        
            my $query = "CREATE TABLE ".$table."_".$newpartname."() INHERITS (".$table.")";
            push(@partsadd,$query);
            $query = "ALTER TABLE ".$table."_".$newpartname." ADD CONSTRAINT chk_".$table."_".$newpartname." CHECK (".$part_key." < to_timestamp(".$curtstamp."))";
            push(@partsadd,$query);
        }
        if($curtstamp >= $stopstamp) {
            print "Stop partition: [$curtstamp] > [$stopstamp]. Last partition: [$newpartname]\n" if($CONFIG->{"SYSTEM"}{"debug"} == 1);
            last;
        }
     }

     my $parts_count=scalar @partsadd;
     if($parts_count > 0) {
        # Fix MAXVALUE. Thanks Dorn B. <djbinter@gmail.com> for report and fix.
        my $query = join(';'."\n", @partsadd).";";
        say "Alter partition: [$query]" if($CONFIG->{"SYSTEM"}{"debug"} == 1);
        $db->do($query) or printf(STDERR "Failed to execute query [%s] with error: %s\n", $query, $db->errstr) if($CONFIG->{"SYSTEM"}{"exec"} == 1);
        if (!$db->{Executed}) {
            print "Couldn't add partition: $minpart\n";
            break;
        }
     }
}


sub read_config {

	my $ini = shift;

	open (INI, "$ini") || die "Can't open $ini: $!\n";
    my $section;
    my $CONFIG;
    while (<INI>) {
        chomp;
        if (/^\s*\[(\w+)\].*/) {
            $section = $1;
        }
        if ((/^(.*)=(.*)$/)) {
            my ($keyword, $value) = split(/=/, $_, 2);
            $keyword =~ s/^\s+|\s+$//g;
            $value =~ s/(#.*)$//;
            $value =~ s/^\s+//;
            $value =~ s/\s+$//;
            #Debug
            #print "V: [$value]\n";
            $CONFIG->{$section}{$keyword} = $value;
        }
    }
	close(INI);
    return $CONFIG;
}


1;
