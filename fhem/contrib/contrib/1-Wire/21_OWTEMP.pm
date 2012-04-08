########################################################################################
#
# OWTEMP.pm
#
# FHEM module to commmunicate with 1-Wire temperature sensors DS1820, DS18S20, DS18B20, DS1822
#
# Attention: This module works as a replacement for the standard 21_OWTEMP.pm,
#            therefore may communicate with the 1-Wire File System OWFS,
#            but also with the newer and more direct OWX module
#
# Prefixes for subroutines of this module:
# OW   = General 1-Wire routines (Martin Fischer, Peter Henning)
# OWFS = 1-Wire file system (Martin Fischer)
# OWX  = 1-Wire bus master interface (Peter Henning)
#
# Prof. Dr. Peter A. Henning, 2012
# Martin Fischer, 2011
# 
# Version 1.11 - March, 2012
#   
# Setup bus device in fhem.cfg as
#
# define <name> OWTEMP [<model>] <ROM_ID> [interval]
#
# where <name> may be replaced by any name string 
#     
#       <model> is a 1-Wire device type. If omitted, we assume this to be an
#              DS1820 temperature sensor 
#              Currently allowed values are DS1820, DS1822
#       <ROM_ID> is a 12 character (6 byte) 1-Wire ROM ID 
#                without Family ID, e.g. A2D90D000800 
#       [interval] is an optional query interval in seconds
#
# get <name> id          => OW_FAMILY.ROM_ID.CRC 
# get <name> present     => 1 if device present, 0 if not
# get <name> interval    => query interval
# get <name> temperature => temperature measurement
# get <name> alarm       => alarm temperature settings
#
# set <name> interval    => set period for measurement
# set <name> tempLow     => lower alarm temperature setting 
# set <name> tempHigh    => higher alarm temperature setting
#
# Additional attributes are defined in fhem.cfg
# Note: attributes "tempXXXX" are read during every update operation.
#
# attr <name> stateAL  "<string>"  = character string for denoting low alarm condition, default is red down triangle
# attr <name> stateAH  "<string>"  = character string for denoting high alarm condition, default is red up triangle
# attr <name> tempOffset <float>   = temperature offset in degree Celsius added to the raw temperature reading 
# attr <name> tempUnit  <string>   = unit of measurement, e.g. Celsius/Kelvin/Fahrenheit or C/K/F, default is Celsius
# attr <name> tempLow   <float>    = measurement value for low alarm 
# attr <name> tempHigh  <float>    = measurement for high alarm 
#
########################################################################################
#
#  This programm is free software; you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation; either version 2 of the License, or
#  (at your option) any later version.
#
#  The GNU General Public License can be found at
#  http://www.gnu.org/copyleft/gpl.html.
#  A copy is found in the textfile GPL.txt and important notices to the license
#  from the author is found in LICENSE.txt distributed with these scripts.
#
#  This script is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
########################################################################################
package main;

#-- Prototypes to make komodo happy
use vars qw{%attr %defs};
use strict;
use warnings;
sub Log($$);

#-- temperature globals - always the raw values from the device
my $owg_temp     = 0;
my $owg_th       = 0;
my $owg_tl       = 0;

#-- variables for display strings
my $stateal;
my $stateah;

my %gets = (
  "id"          => "",
  "present"     => "",
  "interval"    => "",
  "temperature" => "",
  "alarm"       => ""
);

my %sets = (
  "interval"    => "",
  "tempHigh"    => "",
  "tempLow"     => ""
);

my %updates = (
  "present"     => "",
  "temperature" => "",
  "alarm"       => ""
);

########################################################################################
#
# The following subroutines are independent of the bus interface
#
# Prefix = OWTEMP
#
########################################################################################
#
# OWTEMP_Initialize
#
# Parameter hash = hash of device addressed
#
########################################################################################

sub OWTEMP_Initialize ($) {
  my ($hash) = @_;

  $hash->{DefFn}   = "OWTEMP_Define";
  $hash->{UndefFn} = "OWTEMP_Undef";
  $hash->{GetFn}   = "OWTEMP_Get";
  $hash->{SetFn}   = "OWTEMP_Set";
  #tempOffset = a temperature offset added to the temperature reading for correction 
  #tempUnit   = a unit of measure: C/F/K
  $hash->{AttrList}= "IODev do_not_notify:0,1 showtime:0,1 loglevel:0,1,2,3,4,5 ".
                     "stateAL stateAH ".
                     "tempOffset tempUnit:C,Celsius,F,Fahrenheit,K,Kelvin ".
                     "tempLow tempHigh";
  }
  
########################################################################################
#
# OWTEMP_Define - Implements DefFn function
# 
# Parameter hash = hash of device addressed, def = definition string
#
########################################################################################

sub OWTEMP_Define ($$) {
  my ($hash, $def) = @_;
  
  # define <name> OWTEMP [<model>] <id> [interval]
  # e.g.: define flow OWTEMP 525715020000 300
  my @a = split("[ \t][ \t]*", $def);
  
  my ($name,$model,$fam,$id,$crc,$interval,$ret);
  my $tn = TimeNow();
  
  #-- default
  $name          = $a[0];
  $interval      = 300;
  $ret           = "";

  #-- check syntax
  return "OWTEMP: Wrong syntax, must be define <name> OWTEMP [<model>] <id> [interval]"
       if(int(@a) < 2 || int(@a) > 6);
       
  #-- check if this is an old style definition, e.g. <model> is missing
  my $a2 = $a[2];
  my $a3 = defined($a[3]) ? $a[3] : "";
  if(  ($a2 eq "none") || ($a3 eq "none")  ) {
    return "OWTEMP: ID = none is obsolete now, please redefine";
  } elsif( $a2 =~ m/^[0-9|a-f|A-F]{12}$/ ) {
    $model         = "DS1820";
    $id            = $a[2];
    if(int(@a)>=4) { $interval = $a[3]; }
    Log 1, "OWTEMP: Parameter [alarminterval] is obsolete now - must be set with I/O-Device"
      if(int(@a) == 5);
  } elsif( $a3 =~ m/^[0-9|a-f|A-F]{12}$/ ) {
    $model         = $a[2];
    $id            = $a[3];
    if(int(@a)>=5) { $interval = $a[4]; }
    Log 1, "OWTEMP: Parameter [alarminterval] is obsolete now - must be set with I/O-Device"
      if(int(@a) == 6);
  } else {    
    return "OWTEMP: $a[0] ID $a[2] invalid, specify a 12 digit value";
  }

  #-- 1-Wire ROM identifier in the form "FF.XXXXXXXXXXXX.YY"
  #   FF = family id follows from the model
  #   YY must be determined from id
  if( $model eq "DS1820" ){
    $fam = "10";
  }elsif( $model eq "DS1822" ){
    $fam = "22";
  }elsif( $model eq "DS18B20" ){
    $fam = "28";
  }else{
    return "OWTEMP: Wrong 1-Wire device model $model";
  }
  # determine CRC Code - only if this is a direct interface
  $crc = defined($hash->{IODev}->{INTERFACE}) ?  sprintf("%02x",OWX_CRC($fam.".".$id."00")) : "00";
  
  #-- define device internals
  $hash->{ALARM}      = 0;
  $hash->{OW_ID}      = $id;
  $hash->{OW_FAMILY}  = $fam;
  $hash->{PRESENT}    = 0;
  $hash->{ROM_ID}     = $fam.".".$id.$crc;
  $hash->{INTERVAL}   = $interval;

  #-- Couple to I/O device
  AssignIoPort($hash);
  Log 3, "OWTEMP: Warning, no 1-Wire I/O device found for $name."
    if(!defined($hash->{IODev}->{NAME}));
  $modules{OWTEMP}{defptr}{$id} = $hash;
  $hash->{STATE} = "Defined";
  Log 3, "OWTEMP: Device $name defined."; 
  
  #-- Start timer for initialization in a few seconds
  InternalTimer(time()+1, "OWTEMP_InitializeDevice", $hash, 0);
   
  #-- Start timer for updates
  InternalTimer(time()+$hash->{INTERVAL}, "OWTEMP_GetValues", $hash, 0);

  return undef; 
}
  
########################################################################################
#
# OWTEMP_InitializeDevice - delayed setting of initial readings and channel names  
#
#  Parameter hash = hash of device addressed
#
########################################################################################

sub OWTEMP_InitializeDevice($) {
  my ($hash) = @_;
  
  my $name   = $hash->{NAME};
  
  $stateal = defined($attr{$name}{stateAL}) ? $attr{$name}{stateAL} : "<span style=\"color:red\">&#x25BE;</span>";
  $stateah = defined($attr{$name}{stateAH}) ? $attr{$name}{stateAH} : "<span style=\"color:red\">&#x25B4;</span>";
  
  #-- unit attribute defined ?
  $hash->{READINGS}{"temperature"}{UNIT} = defined($attr{$name}{"tempUnit"}) ? $attr{$name}{"tempUnit"} : "Celsius";
  $hash->{READINGS}{"temperature"}{TYPE} = "temperature";
  
  #-- Initial readings temperature sensor
  $owg_temp  =  0.0;
  $owg_tl    = -15.0;
  $owg_th    =  70.0;
 
  #-- Initialize all the display stuff  
  OWTEMP_FormatValues($hash);
}

########################################################################################
#
# OWTEMP_FormatValues - put together various format strings 
#
#  Parameter hash = hash of device addressed, fs = format string
#
########################################################################################

sub OWTEMP_FormatValues($) {
  my ($hash) = @_;
  
  my $name    = $hash->{NAME}; 
  my ($unit,$offset,$factor,$abbr,$vval,$vlow,$vhigh,$statef);
  my ($value1,$value2,$value3)   = ("","","");

  my $tn = TimeNow();
  
  #-- attributes defined ?
  $unit   = defined($attr{$name}{"tempUnit"}) ? $attr{$name}{"tempUnit"} : $hash->{READINGS}{"temperature"}{UNIT};
  $offset = defined($attr{$name}{"tempoffset"}) ? $attr{$name}{"tempOffset"} : 0.0 ;
  $factor = 1.0;
  
  if( $unit eq "Celsius" ){
    $abbr   = "&deg;C";
  } elsif ($unit eq "Kelvin" ){
    $abbr   = "K";
    $offset += "273.16"
  } elsif ($unit eq "Fahrenheit" ){
    $abbr   = "&deg;F";
    $offset = ($offset+32)/1.8;
    $factor = 1.8;
  } else {
    $abbr="?";
    Log 1, "OWTEMP_FormatValues: unknown unit $unit";
  }
  #-- these values are rather coplex to obtain, therefore save them in the hash
  $hash->{READINGS}{"temperature"}{UNIT}     = $unit;
  $hash->{READINGS}{"temperature"}{UNITABBR} = $abbr;
  $hash->{tempf}{offset}                     = $offset;
  $hash->{tempf}{factor}                     = $factor;
  
  #-- correct values for proper offset, factor 
  $vval  = ($owg_temp + $offset)*$factor;
  
  #-- put into READINGS
  $hash->{READINGS}{"temperature"}{VAL}   = $vval;
  $hash->{READINGS}{"temperature"}{TIME}  = $tn;
    
  #-- correct alarm values for proper offset, factor 
  $vlow   = ($owg_tl + $offset)*$factor;
  $vhigh  = ($owg_th + $offset)*$factor;
  
  #-- put into READINGS
  $hash->{READINGS}{"tempLow"}{VAL}     = $vlow;
  $hash->{READINGS}{"tempLow"}{TIME}    = $tn;
  $hash->{READINGS}{"tempHigh"}{VAL}    = $vhigh;
  $hash->{READINGS}{"tempHigh"}{TIME}   = $tn;   
         
  #-- formats for output
  $statef  = "%5.2f ".$abbr;
  $value1 = "temperature: ".sprintf($statef,$vval);
  $value2 = sprintf($statef,$vval);
  $hash->{ALARM} = 1;
  
  #-- Test for alarm condition
  if( ($vval <= $vlow) && ( $vval >= $vhigh ) ){
    $value2 .= " ".$stateal.$stateah;
    $value3 .= " ".$stateal.$stateah;
  }elsif( $vval <= $vlow ){
    $value2 .= " ".$stateal;
    $value3 .= " ".$stateal; 
  }elsif( $vval >= $vhigh ){
    $value2 .= " ".$stateah;
    $value3 .= " ".$stateah;
  } else {
    $hash->{ALARM} = 0;
  }
  
  #-- STATE
  $hash->{STATE} = $value2;
  #-- alarm
  #$hash->{READINGS}{alarms}{VAL}  = $value3;
  #$hash->{READINGS}{alarms}{TIME}   = $tn;
  return $value1;
}
  
########################################################################################
#
# OWTEMP_Get - Implements GetFn function 
#
#  Parameter hash = hash of device addressed, a = argument array
#
########################################################################################

sub OWTEMP_Get($@) {
  my ($hash, @a) = @_;
  
  my $reading = $a[1];
  my $name    = $hash->{NAME};
  my $model   = $hash->{OW_MODEL};
  my $value   = undef;
  my $ret     = "";

  #-- check syntax
  return "OWTEMP: Get argument is missing @a"
    if(int(@a) != 2);
    
  #-- check argument
  return "OWTEMP: Get with unknown argument $a[1], choose one of ".join(",", sort keys %gets)
    if(!defined($gets{$a[1]}));
  
  #-- get id
  if($a[1] eq "id") {
    $value = $hash->{ROM_ID};
     return "$a[0] $reading => $value";
  } 
  
  #-- Get other values according to interface type
  my $interface= $hash->{IODev}->{TYPE};
  
  #-- get present
  if($a[1] eq "present" ) {
    #-- OWX interface
    if( $interface eq "OWX" ){
      #-- hash of the busmaster
      my $master       = $hash->{IODev};
      $value           = OWX_Verify($master,$hash->{ROM_ID});
      $hash->{PRESENT} = $value;
      return "$a[0] $reading => $value";
    } else {
      return "OWTEMP: Verification not yet implemented for interface $interface";
    }
  } 
  
  #-- get interval
  if($reading eq "interval") {
    $value = $hash->{INTERVAL};
     return "$a[0] $reading => $value";
  } 
  
  #-- reset presence
  $hash->{PRESENT}  = 0;

  #-- OWX interface
  if( $interface eq "OWX" ){
    #-- not different from getting all values ..
    $ret = OWXTEMP_GetValues($hash);
  #-- OWFS interface
  }elsif( $interface eq "OWFS" ){
    $ret = OWFSTEMP_GetValues($hash);
  #-- Unknown interface
  }else{
    return "OWTEMP: Get with wrong IODev type $interface";
  }
  
  #-- process results
  if( defined($ret)  ){
    return "OWTEMP: Could not get values from device $name, return was $ret";
  }
  $hash->{PRESENT} = 1; 
  OWTEMP_FormatValues($hash);
  
  #-- return the special reading
  if ($reading eq "temperature") {
    return "OWTEMP: $name.temperature => ".
      $hash->{READINGS}{"temperature"}{VAL};
  } elsif ($reading eq "alarm") {
    return "OWTEMP: $name.alarm => L ".$hash->{READINGS}{"tempLow"}{VAL}.
      " H ".$hash->{READINGS}{"tempHigh"}{VAL};
  }
  return undef;
}

#######################################################################################
#
# OWTEMP_GetValues - Updates the readings from device
#
# Parameter hash = hash of device addressed
#
########################################################################################

sub OWTEMP_GetValues($@) {
  my $hash    = shift;
  
  my $name    = $hash->{NAME};
  my $value   = "";
  my $ret     = "";
  
  #-- restart timer for updates
  RemoveInternalTimer($hash);
  InternalTimer(time()+$hash->{INTERVAL}, "OWTEMP_GetValues", $hash, 1);

  #-- reset presence
  $hash->{PRESENT}  = 0;

  #-- Get values according to interface type
  my $interface= $hash->{IODev}->{TYPE};
  if( $interface eq "OWX" ){
    $ret = OWXTEMP_GetValues($hash);
  }elsif( $interface eq "OWFS" ){
    $ret = OWFSTEMP_GetValues($hash);
  }else{
    return "OWTEMP: GetValues with wrong IODev type $interface";
  }

  #-- process results
  if( defined($ret)  ){
    return "OWTEMP: Could not get values from device $name";
  }
  $hash->{PRESENT} = 1; 
  $value=OWTEMP_FormatValues($hash);
  #--logging
  Log 5, $value;
  $hash->{CHANGED}[0] = $value;
  
  DoTrigger($name, undef);
  
  return undef;
}

#######################################################################################
#
# OWTEMP_Set - Set one value for device
#
#  Parameter hash = hash of device addressed
#            a = argument string
#
########################################################################################

sub OWTEMP_Set($@) {
  my ($hash, @a) = @_;

  #-- for the selector: which values are possible
  return join(" ", sort keys %sets) if(@a == 2);
  #-- check syntax
  return "OWTEMP: Set needs one parameter"
    if(int(@a) != 3);
  #-- check argument
  return "OWTEMP: Set with unknown argument $a[1], choose one of ".join(",", sort keys %sets)
      if(!defined($sets{$a[1]}));
      
  #-- define vars
  my $key   = $a[1];
  my $value = $a[2];
  my $ret   = undef;
  my $name  = $hash->{NAME};
  my $model = $hash->{OW_MODEL};

 #-- set new timer interval
  if($key eq "interval") {
    # check value
    return "OWTEMP: Set with short interval, must be > 1"
      if(int($value) < 1);
    # update timer
    $hash->{INTERVAL} = $value;
    RemoveInternalTimer($hash);
    InternalTimer(gettimeofday()+$hash->{INTERVAL}, "OWTEMP_GetValues", $hash, 1);
    return undef;
  }

  #-- set other values depending on interface type
  my $interface = $hash->{IODev}->{TYPE};
  my $offset    = $hash->{tempf}{offset};
  my $factor    = $hash->{tempf}{factor};
    
  #-- find upper and lower boundaries for given offset/factor
  my $mmin = (-55+$offset)*$factor;
  my $mmax = (125+$offset)*$factor;
  return sprintf("OWTEMP: Set with wrong value $value for $key, range is  [%3.1f,%3.1f]",$mmin,$mmax)
    if($value < $mmin || $value > $mmax);
    
  #-- seems to be ok, put into the device
  $a[2]  = int($value/$factor-$offset);

  #-- OWX interface
  if( $interface eq "OWX" ){
    $ret = OWXTEMP_SetValues($hash,@a);
    return $ret
      if(defined($ret));
  #-- OWFS interface
  }elsif( $interface eq "OWFS" ){
    $ret = OWFSTEMP_SetValues($hash,@a);
    return $ret
      if(defined($ret));
  } else {
  return "OWTEMP: Set with wrong IODev type $interface";
  }
  OWTEMP_FormatValues($hash);
  
  Log 4, "OWTEMP: Set $hash->{NAME} $key $value";
  
  return undef;
}

########################################################################################
#
# OWTEMP_Undef - Implements UndefFn function
#
# Parameter hash = hash of device addressed
#
########################################################################################

sub OWTEMP_Undef ($) {
  my ($hash) = @_;
  
  delete($modules{OWTEMP}{defptr}{$hash->{OW_ID}});
  RemoveInternalTimer($hash);
  return undef;
}

########################################################################################
#
# The following subroutines in alphabetical order are only for a 1-Wire bus connected 
# via OWFS
#
# Prefix = OWFSTEMP
#
########################################################################################
#
# OWFSTEMP_GetValues - Get reading from one device
#
# Parameter hash = hash of device addressed
#
########################################################################################

sub OWFSTEMP_GetValues($)
{
  my ($hash) = @_;

  my $ret = OW::get("/uncached/".$hash->{OW_FAMILY}.".".$hash->{OW_ID}."/temperature");
  if( defined($ret) ) {
    $hash->{PRESENT} = 1;
    $owg_temp = $ret;
    $owg_th   = OW::get("/uncached/".$hash->{OW_FAMILY}.".".$hash->{OW_ID}."/temphigh");
    $owg_tl   = OW::get("/uncached/".$hash->{OW_FAMILY}.".".$hash->{OW_ID}."/templow");
  } else {
    $hash->{PRESENT} = 0;
    $owg_temp = 0.0;
    $owg_th   = 0.0;
    $owg_tl   = 0.0;
  }

  return undef;
}

#######################################################################################
#
# OWFSTEMP_SetValues - Implements SetFn function
# 
# Parameter hash = hash of device addressed
#           a = argument array
#
########################################################################################

sub OWFSTEMP_SetValues($@) {
  my ($hash, @a) = @_;
  
  #-- define vars
  my $key   = lc($a[1]);
  my $value = $a[2];
  
  return OW::put($hash->{OW_FAMILY}.".".$hash->{OW_ID}."/$key",$value);
}

########################################################################################
#
# The following subroutines in alphabetical order are only for a 1-Wire bus connected 
# directly to the FHEM server
#
# Prefix = OWXTEMP
#
########################################################################################
#
# OWXTEMP_GetValues - Get reading from one device
#
# Parameter hash = hash of device addressed
#
########################################################################################

sub OWXTEMP_GetValues($) {

  my ($hash) = @_;
  
  #-- For default, perform the conversion NOT now
  my $con=1;
  
  #-- ID of the device
  my $owx_dev = $hash->{ROM_ID};
  my $owx_rnf = substr($owx_dev,3,12);
  my $owx_f   = substr($owx_dev,0,2);
  
  #-- hash of the busmaster
  my $master = $hash->{IODev};
  
  my ($i,$j,$k);

  #-- 8 byte 1-Wire device address
  my @owx_ROM_ID  =(0,0,0,0 ,0,0,0,0); 
  #-- from search string to byte id
  my $devs=$owx_dev;
  $devs=~s/\.//g;
  for($i=0;$i<8;$i++){
     $owx_ROM_ID[$i]=hex(substr($devs,2*$i,2));
  }
  
  #-- check, if the conversion has been called before - only on devices with real power
  if( defined($attr{$hash->{IODev}->{NAME}}{buspower}) && ( $attr{$hash->{IODev}->{NAME}}{buspower} eq "real") ){
    $con=0;
  }  

  #-- if the conversion has not been called before 
  if( $con==1 ){
    OWX_Reset($master);
    #-- issue the match ROM command \x55 and the start conversion command
    my $select=sprintf("\x55%c%c%c%c%c%c%c%c\x44",@owx_ROM_ID); 
    if( OWX_Block($master,$select) eq 0 ){
      return "OWXTEMP: Device $owx_dev not accessible";
    } 
    #-- conversion needs some 950 ms - but we may also do it in shorter time !
    select(undef,undef,undef,1.0);
  }

  #-- NOW ask the specific device 
  OWX_Reset($master);
  #-- issue the match ROM command \x55 and the read scratchpad command \xBE
  my $select=sprintf("\x55%c%c%c%c%c%c%c%c\xBE\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF",
     @owx_ROM_ID); 
     
  my $res=OWX_Block($master,$select);
  #-- process results
  if( $res eq 0 ){
    return "OWXTEMP: Device $owx_dev not accessible in 2nd step"; 
  }
  #my $res2 = "====> OWXTEMP Received ";
  #for(my $i=0;$i<19;$i++){  
  #  my $j=int(ord(substr($res,$i,1))/16);
  #  my $k=ord(substr($res,$i,1))%16;
  #  $res2.=sprintf "0x%1x%1x ",$j,$k;
  #}
  #Log 1, $res2;
     
  #-- process results
  my  @data=split(//,$res);
  #-- this must be different for the different device types
  #   family = 10 => DS1820, DS18S20
  if( $hash->{OW_FAMILY} eq "10" ) {
    if ( (@data == 19) && (ord($data[17])>0) ){
      my $count_remain = ord($data[16]);
      my $count_perc   = ord($data[17]);
      my $delta        = -0.25 + ($count_perc - $count_remain)/$count_perc;
  
      my $lsb  = ord($data[10]);
      my $msb  = 0;
      my $sign = ord($data[11]) & 255;
      
      #-- 2's complement form = signed bytes
      if( $sign == 0 ){
        $owg_temp = int($lsb/2) + $delta;
      } else {
        $owg_temp = 128-(int($lsb/2) + $delta);
      }
      $owg_th = ord($data[12]) > 127 ? 128-ord($data[12]) : ord($data[12]);
      $owg_tl = ord($data[13]) > 127 ? 128-ord($data[13]) : ord($data[13]);
      return undef;
    } else {
      return "OWXTEMP: Device $owx_dev returns invalid data";
    }
  } elsif ( ($hash->{OW_FAMILY} eq "22") || ($hash->{OW_FAMILY} eq "28") ) {
    if ( (@data == 19) && (ord($data[17])>0) ){
   
      my $lsb  = ord($data[10]);
      my $msb  = ord($data[11]) & 7;
      my $sign = ord($data[11]) & 248;
      
      #-- 2's complement form = signed bytes
      $owg_temp = $msb*16+ $lsb/16;   
      if( $sign !=0 ){
        $owg_temp = 128-$owg_temp;
      }
      $owg_th = ord($data[12]) > 127 ? 128-ord($data[12]) : ord($data[12]);
      $owg_tl = ord($data[13]) > 127 ? 128-ord($data[13]) : ord($data[13]);
      return undef;
    } else {
      return "OWXTEMP: Device $owx_dev returns invalid data";
    }
  } else {
    return "OWXTEMP: Unknown device family $hash->{OW_FAMILY}\n";
  }
}

#######################################################################################
#
# OWXTEMP_SetValues - Implements SetFn function
# 
# Parameter hash = hash of device addressed
#           a = argument array
#
########################################################################################

sub OWXTEMP_SetValues($@) {
  my ($hash, @a) = @_;
  
  my $name = $hash->{NAME};
 
  #-- ID of the device
  my $owx_dev = $hash->{ROM_ID};
  my $owx_rnf = substr($owx_dev,3,12);
  my $owx_f   = substr($owx_dev,0,2);
  
  #-- hash of the busmaster
  my $master = $hash->{IODev};
 
  my ($i,$j,$k);

  #-- 8 byte 1-Wire device address
  my @owx_ROM_ID  =(0,0,0,0 ,0,0,0,0); 
  #-- from search string to byte id
  my $devs=$owx_dev;
  $devs=~s/\.//g;
  for($i=0;$i<8;$i++){
     $owx_ROM_ID[$i]=hex(substr($devs,2*$i,2));
  }
  
  #-- define vars
  my $key   = $a[1];
  my $value = $a[2];
  $owg_tl = $value if( $key eq "tempLow" );
  $owg_th = $value if( $key eq "tempHigh" );

  #-- put into 2's complement formed (signed byte)
  my $tlp = $owg_tl < 0 ? 128 - $owg_tl : $owg_tl; 
  my $thp = $owg_th < 0 ? 128 - $owg_th : $owg_th; 

  OWX_Reset($master);
  
  #-- issue the match ROM command \x55 and the write scratchpad command \x4E,
  #   followed by the write EEPROM command \x48
  #
  #   so far writing the EEPROM does not work properly.
  #   1. \x48 directly appended to the write scratchpad command => command ok, no effect on EEPROM
  #   2. \x48 appended to match ROM => command not ok. 
  #   3. \x48 sent by WriteBytePower after match ROM => command ok, no effect on EEPROM
  
  my $select=sprintf("\x55%c%c%c%c%c%c%c%c\x4E%c%c\x48",@owx_ROM_ID,$thp,$tlp); 
  my $res=OWX_Block($master,$select);

  if( $res eq 0 ){
    return "OWXTEMP: Device $owx_dev not accessible"; 
  } 
  
  #-- issue the match ROM command \x55 and the copy scratchpad command \x48
  #$select=sprintf("\x55%c%c%c%c%c%c%c%c",@owx_ROM_ID); 
  #$res=OWX_Block($hash,$select);
  #$res=OWX_WriteBytePower($hash,"\x48");

  #if( $res eq 0 ){
  #  Log 3, "OWXTEMP_SetTemp: Device $romid not accessible in the second step"; 
  #  return 0;
  #} 
  
  DoTrigger($name, undef) if($init_done);
  return undef;
}



1;