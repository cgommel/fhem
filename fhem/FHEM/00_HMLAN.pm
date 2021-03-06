##############################################
# $Id$
package main;


use strict;
use warnings;
use Time::HiRes qw(gettimeofday time);

sub HMLAN_Initialize($);
sub HMLAN_Define($$);
sub HMLAN_Undef($$);
sub HMLAN_RemoveHMPair($);
sub HMLAN_Attr(@);
sub HMLAN_Set($@);
sub HMLAN_ReadAnswer($$$);
sub HMLAN_Write($$$);
sub HMLAN_Read($);
sub HMLAN_uptime($@);
sub HMLAN_Parse($$);
sub HMLAN_Ready($);
sub HMLAN_SimpleWrite(@);
sub HMLAN_DoInit($);
sub HMLAN_KeepAlive($);
sub HMLAN_secSince2000();
sub HMLAN_relOvrLd($);
sub HMLAN_condUpdate($$);

my $debug = 1; # set 1 for better log readability
my %sets = ( "hmPairForSec" => "HomeMatic"
            ,"hmPairSerial" => "HomeMatic"
);
my %HMcond = ( 0  =>'ok'
              ,2  =>'Warning-HighLoad'
			  ,4  =>'ERROR-Overload'
			  ,253=>'disconnected'
			  ,254=>'Overload-released'
			  ,255=>'init');
			  
my $HMOvLdRcvr = 6*60;# time HMLAN needs to recover from overload

sub HMLAN_Initialize($) {
  my ($hash) = @_;

  require "$attr{global}{modpath}/FHEM/DevIo.pm";

# Provider
  $hash->{ReadFn}  = "HMLAN_Read";
  $hash->{WriteFn} = "HMLAN_Write";
  $hash->{ReadyFn} = "HMLAN_Ready";
  $hash->{SetFn}   = "HMLAN_Set";
  $hash->{AttrFn}  = "HMLAN_Attr";
  $hash->{Clients} = ":CUL_HM:";
  my %mc = (
    "1:CUL_HM" => "^A......................",
  );
  $hash->{MatchList} = \%mc;

# Normal devices
  $hash->{DefFn}   = "HMLAN_Define";
  $hash->{UndefFn} = "HMLAN_Undef";
  $hash->{AttrList}= "do_not_notify:1,0 dummy:1,0 " .
                     "loglevel:0,1,2,3,4,5,6 addvaltrigger " . 
                     "hmId hmKey " .
                     "respTime wdStrokeTime:5,10,15,20,25 " .
					 "hmProtocolEvents:0_off,1_dump,2_dumpFull,3_dumpTrigger ".
					 "hmLanQlen:1_min,2_low,3_normal,4_high,5_critical ".
					 "wdTimer ".
					 $readingFnAttributes;
}
sub HMLAN_Define($$) {#########################################################
  my ($hash, $def) = @_;
  my @a = split("[ \t][ \t]*", $def);

  if(@a != 3) {
    my $msg = "wrong syntax: define <name> HMLAN ip[:port]";
    Log 2, $msg;
    return $msg;
  }
  DevIo_CloseDev($hash);

  my $name = $a[0];
  my $dev = $a[2];
  $dev .= ":1000" if($dev !~ m/:/ && $dev ne "none" && $dev !~ m/\@/);

  if($dev eq "none") {
    Log 1, "$name device is none, commands will be echoed only";
    $attr{$name}{dummy} = 1;
    return undef;
  }
  $attr{$name}{wdTimer} = 25;
  $attr{$name}{hmLanQlen} = "1_min"; #max message queue length in HMLan
  no warnings 'numeric';
  $hash->{helper}{q}{hmLanQlen} = int($attr{$name}{hmLanQlen})+0; 
  use warnings 'numeric';
  $hash->{DeviceName} = $dev;
  
  $hash->{helper}{q}{answerPend} = 0;#pending answers from LANIf
  my @arr = ();
  @{$hash->{helper}{q}{apIDs}} = \@arr;
  
  HMLAN_condUpdate($hash,253);#set disconnected
  my $ret = DevIo_OpenDev($hash, 0, "HMLAN_DoInit");
  return $ret;
}
sub HMLAN_Undef($$) {##########################################################
  my ($hash, $arg) = @_;
  my $name = $hash->{NAME};

  foreach my $d (sort keys %defs) {
    if(defined($defs{$d}) &&
       defined($defs{$d}{IODev}) &&
       $defs{$d}{IODev} == $hash)
      {
        my $lev = ($reread_active ? 4 : 2);
        Log GetLogLevel($name,$lev), "deleting port for $d";
        delete $defs{$d}{IODev};
      }
  }
  DevIo_CloseDev($hash); 
  return undef;
}
sub HMLAN_RemoveHMPair($) {####################################################
  my($in ) = shift;
  my(undef,$name) = split(':',$in);
  my $hash = $defs{$name};
  delete($hash->{hmPair});
}
sub HMLAN_Attr(@) {#################################
  my ($cmd,$name, $attrName,$aVal) = @_;
  if   ($attrName eq "wdTimer"){#allow between 5 and 25 second
    return "select wdTimer between 5 and 25 seconds" if ($aVal>25 || $aVal<5);
    $attr{$name}{wdTimer} = $aVal;
  }
  elsif($attrName eq "hmLanQlen"){
	if ($cmd eq "set"){
      no warnings 'numeric';
      $defs{$name}{helper}{q}{hmLanQlen} = int($aVal)+0; 
      use warnings 'numeric';
	}
	else{
	  $defs{$name}{helper}{q}{hmLanQlen} = 1;
	}
  }
  return;
}

sub HMLAN_Set($@) {############################################################
  my ($hash, @a) = @_;

  return "\"set HMLAN\" needs at least one parameter" if(@a < 2);
  return "Unknown argument $a[1], choose one of " . join(" ", sort keys %sets)
  	if(!defined($sets{$a[1]}));

  my $name = shift @a;
  my $type = shift @a;
  my $arg = join("", @a);
  my $ll = GetLogLevel($name,3);
  if($type eq "hmPairForSec") { ####################################
    return "Usage: set $name hmPairForSec <seconds_active>"
        if(!$arg || $arg !~ m/^\d+$/);
    $hash->{hmPair} = 1;
    InternalTimer(gettimeofday()+$arg, "HMLAN_RemoveHMPair", "hmPairForSec:".$hash, 1);

  } 
  elsif($type eq "hmPairSerial") { ################################
    return "Usage: set $name hmPairSerial <10-character-serialnumber>"
        if(!$arg || $arg !~ m/^.{10}$/);

    my $id = AttrVal($hash->{NAME}, "hmId", "123456");
    $hash->{HM_CMDNR} = $hash->{HM_CMDNR} ? ($hash->{HM_CMDNR}+1)%256 : 1;

    HMLAN_Write($hash, undef, sprintf("As15%02X8401%s000000010A%s",
                    $hash->{HM_CMDNR}, $id, unpack('H*', $arg)));
    $hash->{hmPairSerial} = $arg;

  }
  return undef;
}
sub HMLAN_ReadAnswer($$$) {# This is a direct read for commands like get
  my ($hash, $arg, $regexp) = @_;
  my $type = $hash->{TYPE};

  return ("No FD", undef)
        if(!$hash && !defined($hash->{FD}));

  my ($mdata, $rin) = ("", '');
  my $buf;
  my $to = 3;                                         # 3 seconds timeout
  $to = $hash->{RA_Timeout} if($hash->{RA_Timeout});  # ...or less
  for(;;) {

    return ("Device lost when reading answer for get $arg", undef)
      if(!$hash->{FD});
    vec($rin, $hash->{FD}, 1) = 1;
    my $nfound = select($rin, undef, undef, $to);
    if($nfound < 0) {
      next if ($! == EAGAIN() || $! == EINTR() || $! == 0);
      my $err = $!;
      DevIo_Disconnected($hash);
	  HMLAN_condUpdate($hash,253);
      return("HMLAN_ReadAnswer $arg: $err", undef);
    }
    return ("Timeout reading answer for get $arg", undef) if($nfound == 0);
    $buf = DevIo_SimpleRead($hash);# and now read
    return ("No data", undef) if(!defined($buf));

    if($buf) {
      Log 5, "HMLAN/RAW (ReadAnswer): $buf";
      $mdata .= $buf;
    }
    if($mdata =~ m/\r\n/) {
      if($regexp && $mdata !~ m/$regexp/) {
        HMLAN_Parse($hash, $mdata);
      } 
	  else {
        return (undef, $mdata);
      }
    }
  }
}

my %lhash; # remember which ID is assigned to this HMLAN

sub HMLAN_Write($$$) {#########################################################
  my ($hash,$fn,$msg) = @_;
  if (length($msg)>22){
    my ($mtype,$src,$dst) = (substr($msg, 8, 2),
                             substr($msg, 10, 6),
	  					     substr($msg, 16, 6));
    my $ll5 = GetLogLevel($hash->{NAME},5);						   
    
    if ($mtype eq "02" && $src eq $hash->{owner} && length($msg) == 24){
      # Acks are generally send by HMLAN autonomously
      # Special 
      Log $ll5, "HMLAN: Skip ACK" if (!$debug);
	  return;
    }
#   my $IDHM  = '+'.$dst.',01,00,F1EF'; #used by HMconfig - meanning??
#   my $IDadd = '+'.$dst;               # guess: add ID?                                     
#   my $IDack = '+'.$dst.',02,00,';     # guess: ID acknowledge
#   my $IDack = '+'.$dst.',FF,00,';     # guess: ID acknowledge
#   my $IDsub = '-'.$dst;               # guess: ID remove?
#   my $IDnew = '+'.$dst.',00,01,';     # newChannel- trailing 01 to be sent if talk to neu channel
    my $IDadd = '+'.$dst.',00,00,';     # guess: add ID?                                     
    
    if (!$lhash{$dst} && $dst ne "000000"){
      HMLAN_SimpleWrite($hash, $IDadd);
	  delete $hash->{helper}{$dst};
	  my $dN = CUL_HM_id2Name($dst);
	  if (!($dN eq $dst) &&  # name not found
	      !(CUL_HM_Get(CUL_HM_id2Hash($dst),$dN,"param","rxType") & ~0x04)){#config only
	    $hash->{helper}{$dst}{newChn} = '+'.$dst.",01,01,FE1F";
      }
	  else{
	    $hash->{helper}{$dst}{newChn} = '+'.$dst.',00,01,';
	  }
	  $hash->{helper}{$dst}{name} = CUL_HM_id2Name($dst);
      $lhash{$dst} = 1;
      $hash->{assignIDs}=join(',',keys %lhash);
      $hash->{assignIDsCnt}=scalar(keys %lhash);
    }
  }
  my $tm = int(gettimeofday()*1000) % 0xffffffff;
  $msg = sprintf("S%08X,00,00000000,01,%08X,%s",$tm, $tm, substr($msg, 4));
  HMLAN_SimpleWrite($hash, $msg);
}
sub HMLAN_Read($) {############################################################
# called from the global loop, when the select for hash->{FD} reports data
  my ($hash) = @_;
  my $buf = DevIo_SimpleRead($hash);
  return "" if(!defined($buf));
  my $name = $hash->{NAME};
  my $ll5 = GetLogLevel($name,5);
  
  my $hmdata = $hash->{PARTIAL};
  Log $ll5, "HMLAN/RAW: $hmdata/$buf" if (!$debug);
  $hmdata .= $buf;

  while($hmdata =~ m/\n/) {
    my $rmsg;
    ($rmsg,$hmdata) = split("\n", $hmdata, 2);
    $rmsg =~ s/\r//;
    HMLAN_Parse($hash, $rmsg) if($rmsg);
  }
  $hash->{PARTIAL} = $hmdata;
}
sub HMLAN_uptime($@) {#########################################################
  my ($hmtC,$hash) = @_;  # hmTime Current

  $hmtC = hex($hmtC);

  if ($hash && $hash->{helper}{ref}){ #will calculate new ref-time
	my $ref = $hash->{helper}{ref};#shortcut
    my $sysC = int(time()*1000);   #current systime in ms
	my $offC = $sysC - $hmtC;      #offset calc between time and HM-stamp
	if ($ref->{hmtL} && ($hmtC > $ref->{hmtL})){
	  if (($sysC - $ref->{kTs})<20){ #if delay is more then 20ms, we dont trust
	    if ($ref->{sysL}){
	      $ref->{drft} = ($offC - $ref->{offL})/($sysC - $ref->{sysL});        
	    }
        $ref->{sysL} = $sysC;
        $ref->{offL} = $offC;
	  }
	}
	else{# hm had a skip in time, start over calculation
	  delete $hash->{helper}{ref};
	}
	$hash->{helper}{ref}{hmtL} = $hmtC;
	$hash->{helper}{ref}{kTs} = 0;
  }

  my $sec = int($hmtC/1000);  
  return sprintf("%03d %02d:%02d:%02d.%03d",
                  int($hmtC/86400000), int($sec/3600),
                  int(($sec%3600)/60), $sec%60, $hmtC % 1000);
}
sub HMLAN_Parse($$) {##########################################################
  my ($hash, $rmsg) = @_;
  my $name = $hash->{NAME};
  my $ll5 = GetLogLevel($name,5);
  my @mFld = split(',', $rmsg);
  my $letter = substr($mFld[0],0,1); # get leading char
  
  if ($letter =~ m/^[ER]/){#@mFld=($src, $status, $msec, $d2, $rssi, $msg)
    # max speed for devices is 100ms after receive - example:TC

	my ($mNo,$flg,$type,$src,$dst,$p) = unpack('A2A2A2A6A6A*',$mFld[5]);
    my $CULinfo = "";
    Log $ll5, "HMLAN_Parse: $name R:".$mFld[0]
	                               .(($mFld[0] =~ m/^E/)?'  ':'')
	                               .' stat:' .$mFld[1]
	                               .' t:'    .$mFld[2]
								   .' d:'    .$mFld[3]
								   .' r:'    .$mFld[4] 
                                   .'     m:'.$mNo
                                   .' '.$flg.$type
                                   .' '.$src
                                   .' '.$dst
                                   .' '.$p;
								  
    # handle status. 
	#HMcond stat
	#    00 00= msg without relation
	#    00 01= ack that HMLAN waited for
	#    00 02= msg send, no ack requested
	#    00 08= nack - ack was requested, msg repeated 3 times, still no ack
	#    00 21= ??(seen with 'R') - see below
	#    00 2x= should: AES was accepted, here is the response
	#    00 30= should: AES response failed
	#    00 40= ??(seen with 'E') after 0100
	#    00 41= ??(seen with 'R')
	#    00 50= ??(seen with 'R')
	#    00 81= ??
	#    01 xx= ?? 0100 AES response send (gen autoMsgSent)
	#    02 xx= prestate to 04xx. Message is still sent. This is a warning
	#    04 xx= nothing sent anymore. Any restart unsuccessful except power
	# 
	#  parameter 'cond'- condition of the IO device
	#  Cond text
	#     0 ok
	#     2 Warning-HighLoad
	# 
    my $stat = hex($mFld[1]);
    my $HMcnd =$stat >>8; #high = HMLAN cond
	$stat &= 0xff;        # low byte related to message format

	if ($HMcnd == 0x01){#HMLAN responded to AES request
#	  $CULinfo = "AESresp";# General needs approval
	}
	if ($stat){# message with status information
	  HMLAN_condUpdate($hash,$HMcnd)if ($hash->{helper}{q}{HMcndN} != $HMcnd);

	  if    ($stat & 0x03 && $dst eq $attr{$name}{hmId}){HMLAN_qResp($hash,$src,0);}
	  elsif ($stat & 0x08 && $src eq $attr{$name}{hmId}){HMLAN_qResp($hash,$dst,0);}
	  
	  $hash->{helper}{$dst}{flg} = 0;#got response => unblock sending
      if ($stat & 0x0A){#08 and 02 dont need to go to CUL, internal ack only
	    Log $ll5, "HMLAN_Parse: $name no ACK from $dst"   if($stat & 0x08);
	    return;
	  }elsif (($stat & 0x70) == 0x30){Log $ll5, "HMLAN_Parse: $name AES code rejected for $dst $stat";
		                              $CULinfo = "AESerrReject"; 
	  }elsif (($stat & 0x70) == 0x20){$CULinfo = "AESok";
	  }elsif (($stat & 0x70) == 0x40){;#$CULinfo = "???";
	  }	  
    }

    my $rssi = hex($mFld[4])-65536;
     #update some User information ------
	$hash->{uptime} = HMLAN_uptime($mFld[2]);
	$hash->{RSSI}   = $rssi;
    $hash->{RAWMSG} = $rmsg;
    $hash->{"${name}_MSGCNT"}++;
    $hash->{"${name}_TIME"} = TimeNow();

	my $dly = 0; #--------- calc messageDelay ----------
    if ($hash->{helper}{ref} && $hash->{helper}{ref}{drft}){
      my $ref = $hash->{helper}{ref};#shortcut
      my $sysC = int(time()*1000);   #current systime in ms
      $dly = int($sysC - (hex($mFld[2]) + $ref->{offL} + $ref->{drft}*($sysC - $ref->{sysL})));

	  $hash->{helper}{dly}{lst} = $dly;
	  my $dlyP = $hash->{helper}{dly};
	  $dlyP->{min} = $dly if (!$dlyP->{min} || $dlyP->{min}>$dly);
	  $dlyP->{max} = $dly if (!$dlyP->{max} || $dlyP->{max}<$dly);
	  if ($dlyP->{cnt}) {$dlyP->{cnt}++} else {$dlyP->{cnt} = 1} ;
	  
	  $hash->{msgParseDly} =   "min:" .$dlyP->{min}
	                         ." max:" .$dlyP->{max}
						     ." last:".$dlyP->{lst}
						     ." cnt:" .$dlyP->{cnt};	  
	  $dly = 0 if ($dly<0);	  
    }

	# HMLAN sends ACK for flag 'A0' but not for 'A4'(config mode)- 
	# we ack ourself an long as logic is uncertain - also possible is 'A6' for RHS
	if (hex($flg)&0x4){#not sure: 4 oder 2 ? 
	  my $wait = 0.100 - $dly/1000;
	  $hash->{helper}{$src}{nextSend} = gettimeofday() + $wait if ($wait > 0);
	}
	if (hex($flg)&0xA4 == 0xA4 && $hash->{owner} eq $dst){
	  Log $ll5, "HMLAN_Parse: $name ACK config";
	  HMLAN_Write($hash,undef, "As15".$mNo."8002".$dst.$src."00");
	}
	
    if ($letter eq 'R' && $hash->{helper}{$src}{flg}){
	  $hash->{helper}{$src}{flg} = 0;                 #release send-holdoff
	  if ($hash->{helper}{$src}{msg}){                #send delayed msg if any
	    Log $ll5,"HMLAN_SdDly: $name $src";
		HMLAN_SimpleWrite($hash, $hash->{helper}{$src}{msg});
	  }
	  $hash->{helper}{$src}{msg} = "";                #clear message
	}
	# prepare dispatch-----------
    # HM format A<len><msg>:<info>:<RSSI>:<IOname>  Info is not used anymore
    my $dmsg = sprintf("A%02X%s:$CULinfo:$rssi:$name", 
	                     length($mFld[5])/2, uc($mFld[5]));
    my %addvals = (RAWMSG => $rmsg, RSSI => hex($mFld[4])-65536);
    Dispatch($hash, $dmsg, \%addvals);
  }
  elsif($mFld[0] eq 'HHM-LAN-IF'){#HMLAN version info
    $hash->{serialNr} = $mFld[2];
    $hash->{firmware} = sprintf("%d.%d", (hex($mFld[1])>>12)&0xf, hex($mFld[1]) & 0xffff);
    $hash->{owner} = $mFld[4];
    $hash->{uptime} = HMLAN_uptime($mFld[5],$hash);
   	$hash->{assignIDsReport}=hex($mFld[6]);
    $hash->{helper}{q}{keepAliveRec} = 1;
    $hash->{helper}{q}{keepAliveRpt} = 0;
    Log $ll5, 'HMLAN_Parse: '.$name.                 ' V:'.$mFld[1]
	                               .' sNo:'.$mFld[2].' d:'.$mFld[3]
								   .' O:'  .$mFld[4].' t:'.$mFld[5].' IDcnt:'.$mFld[6];
    my $myId = AttrVal($name, "hmId", "");
	$myId = $attr{$name}{hmId} = $mFld[4] if (!$myId);
	
    if($mFld[4] ne $myId && !AttrVal($name, "dummy", 0)) {
      Log 1, 'HMLAN setting owner to '.$myId.' from '.$mFld[4];
      HMLAN_SimpleWrite($hash, "A$myId");
    }
  }
  elsif($rmsg =~ m/^I00.*/) {;
    # Ack from the HMLAN
  } 
  else {
    Log $ll5, "$name Unknown msg >$rmsg<";
  }
}
sub HMLAN_Ready($) {###########################################################
  my ($hash) = @_;
  return DevIo_OpenDev($hash, 1, "HMLAN_DoInit");
}
sub HMLAN_SimpleWrite(@) {#####################################################
  my ($hash, $msg, $nonl) = @_;

  return if(!$hash || AttrVal($hash->{NAME}, "dummy", undef));
  HMLAN_condUpdate($hash,253) if ($hash->{STATE} eq "disconnected");#closed?
  
  my $name = $hash->{NAME};
  my $ll5 = GetLogLevel($name,5);
  my $len = length($msg);
  
  # It is not possible to answer befor 100ms

  if ($len>51){
    if($hash->{helper}{q}{HMcndN}){
	  my $HMcnd = $hash->{helper}{q}{HMcndN};
	  return if ($HMcnd == 4 || $HMcnd == 253);# no send if overload or disconnect
    }

    my $dst = substr($msg,46,6);
	my $hDst = $hash->{helper}{$dst};# shortcut
    if ($hDst->{nextSend}){
      my $DevDelay = $hDst->{nextSend} - gettimeofday();
      select(undef, undef, undef, (($DevDelay > 0.1)?0.1:$DevDelay))
	        if ($DevDelay > 0.01);
	  delete $hDst->{nextSend};
    }
	if ($dst ne $attr{$name}{hmId}){  #delay send if answer is pending
	  if ( $hDst->{flg} &&                #HMLAN's ack pending
          ($hDst->{to} > gettimeofday())){#won't wait forever!
	    $hDst->{msg} = $msg;              #postpone  message
	    Log $ll5,"HMLAN_Delay: $name $dst";
	    return;
	  }
      my $flg = substr($msg,36,2);
	  $hDst->{flg} = (hex($flg)&0x20)?1:0;# answer expected?
      $hDst->{to} = gettimeofday() + 2;# flag timeout after 2 sec
	  $hDst->{msg} = "";

	  if ($hDst->{flg} == 1 &&
          substr($msg,40,6) eq $attr{$name}{hmId}){
		HMLAN_qResp($hash,$dst,1);
	  }	  
	}
    if ($len > 52){#channel information included, send sone kind of clearance
	  my $chn = substr($msg,52,2);
	  if ($hDst->{chn} && $hDst->{chn} ne $chn){
	    my $updt = $hDst->{newChn};
        Log $ll5, 'HMLAN_Send:  '.$name.' S:'.$updt; 
	    syswrite($hash->{TCPDev}, $updt."\r\n")     if($hash->{TCPDev});
	  }
	  $hDst->{chn} = $chn;
	} 
    $msg =~ m/(.{9}).(..).(.{8}).(..).(.{8}).(..)(....)(.{6})(.{6})(.*)/;
	Log $ll5, 'HMLAN_Send:  '.$name.' S:'.$1
                             .' stat:  ' .$2
                             .' t:'      .$3
                             .' d:'      .$4
                             .' r:'      .$5 
                             .' m:'      .$6
                             .' '        .$7 
                             .' '        .$8
                             .' '        .$9
                             .' '        .$10;
  }
  else{
    Log $ll5, 'HMLAN_Send:  '.$name.' I:'.$msg; 
  }
  
  $msg .= "\r\n" unless($nonl);
  syswrite($hash->{TCPDev}, $msg)     if($hash->{TCPDev});
}
sub HMLAN_DoInit($) {##########################################################
  my ($hash) = @_;
  my $name = $hash->{NAME};

  my $id  = AttrVal($name, "hmId", undef);
  my $key = AttrVal($name, "hmKey", "");        # 36(!) hex digits

  my $s2000 = sprintf("%02X", HMLAN_secSince2000());

  HMLAN_SimpleWrite($hash, "A$id") if($id);
  HMLAN_SimpleWrite($hash, "C");
  HMLAN_SimpleWrite($hash, "Y01,01,$key");
  HMLAN_SimpleWrite($hash, "Y02,00,");
  HMLAN_SimpleWrite($hash, "Y03,00,");
  HMLAN_SimpleWrite($hash, "Y03,00,");
  HMLAN_SimpleWrite($hash, "T$s2000,04,00,00000000");
  delete $hash->{helper}{ref};

  HMLAN_condUpdate($hash,0xff);
  RemoveInternalTimer( "Overload:".$name);

  foreach (keys %lhash){delete ($lhash{$_})};# clear IDs - HMLAN might have a reset 
  $hash->{helper}{q}{keepAliveRec} = 1; # ok for first time
  $hash->{helper}{q}{keepAliveRpt} = 0; # ok for first time

  RemoveInternalTimer( "keepAliveCk:".$name);# avoid duplicate timer
  RemoveInternalTimer( "keepAlive:".$name);# avoid duplicate timer
  InternalTimer(gettimeofday()+$attr{$name}{wdTimer}, "HMLAN_KeepAlive", "keepAlive:".$name, 0);
  return undef;
}
sub HMLAN_KeepAlive($) {#######################################################
  my($in ) = shift;
  my(undef,$name) = split(':',$in);
  my $hash = $defs{$name};
  $hash->{helper}{q}{keepAliveRec} = 0; # reset indicator

  return if(!$hash->{FD});
  HMLAN_SimpleWrite($hash, "K");
  $hash->{helper}{ref}{kTs} = int(time()*1000);
  RemoveInternalTimer( "keepAlive:".$name);# avoid duplicate timer
  my $rt = AttrVal($name,"respTime",1);
  InternalTimer(gettimeofday()+$rt,"HMLAN_KeepAliveCheck","keepAliveCk:".$name,1);
  $attr{$name}{wdTimer} = 25 if (!$attr{$name}{wdTimer});
  InternalTimer(gettimeofday()+$attr{$name}{wdTimer} ,"HMLAN_KeepAlive", "keepAlive:".$name, 1);
}
sub HMLAN_KeepAliveCheck($) {##################################################
  my($in ) = shift;
  my(undef,$name) = split(':',$in);
  my $hash = $defs{$name};
  if ($hash->{helper}{q}{keepAliveRec} != 1){# no answer
    if ($hash->{helper}{q}{keepAliveRpt} >2){# give up here
      DevIo_Disconnected($hash);
	  HMLAN_condUpdate($hash,253);
    }
    else{
      $hash->{helper}{q}{keepAliveRpt}++;
	  HMLAN_KeepAlive("keepAlive:".$name);#repeat
    }
  }
  else{
    $hash->{helper}{q}{keepAliveRpt}=0;
  }

}
sub HMLAN_secSince2000() {#####################################################
  # Calculate the local time in seconds from 2000.
  my $t = time();
  my @l = localtime($t);
  my @g = gmtime($t);
  $t += 60*(($l[2]-$g[2] + ((($l[5]<<9)|$l[7]) <=> (($g[5]<<9)|$g[7])) * 24) * 60 + $l[1]-$g[1]) 
                           # timezone and daylight saving...
        - 946684800        # seconds between 01.01.2000, 00:00 and THE EPOCH (1970)
        - 7200;            # HM Special
  return $t;
}
sub HMLAN_qResp($$$) {#response-waiting queue##################################
  my($hash,$id,$cmd) = @_;
  my $hashQ = $hash->{helper}{q};
  if ($cmd){
    $hashQ->{answerPend} ++;
	push @{$hashQ->{apIDs}},$id;
	$hash->{XmitOpen} = 0 if ($hashQ->{answerPend} >= $hashQ->{hmLanQlen});
  }
  else{
    $hashQ->{answerPend}-- if ($hashQ->{answerPend}>0);
	@{$hashQ->{apIDs}}=grep !/$id/,@{$hashQ->{apIDs}};
	$hash->{XmitOpen} = 1 
	        if (($hashQ->{answerPend} < $hashQ->{hmLanQlen}) &&
			    !($hashQ->{HMcndN} == 4 || 
				  $hashQ->{HMcndN} == 253)
			   );
  }
	
#  Log 1,"General max:$hashQ->{hmLanQlen} cmd:$cmd"
#		   ."/".$hash->{XmitOpen}
#           ." :".$hashQ->{answerPend}
#		   ."/".@{$hashQ->{apIDs}}
#		   .":".join("-",@{$hashQ->{apIDs}})
#		   .":$debug" ;
}
sub HMLAN_relOvrLd($) {########################################################
  my(undef,$name) = split(':',$_[0]);
  HMLAN_condUpdate($defs{$name},0xFE);
  $defs{$name}{STATE} = "opened";
}
sub HMLAN_condUpdate($$) {#####################################################
  my($hash,$HMcnd) = @_;
  my $name = $hash->{NAME};
  my $hashCnd = $hash->{helper}{cnd};#short to helper
  my $hashQ   = $hash->{helper}{q};#short to helper
  $hashCnd->{$HMcnd} = 0 if (!$hashCnd->{$HMcnd});
  $hashCnd->{$HMcnd}++;
  if ($HMcnd == 4){#HMLAN needs a rest. Supress all sends exept keep alive
    InternalTimer(gettimeofday()+$HMOvLdRcvr,"HMLAN_relOvrLd","Overload:".$name,1);
    $hash->{STATE} = "overload";
  }

  my $HMcndTxt = $HMcond{$HMcnd}?$HMcond{$HMcnd}:"Unknown:$HMcnd";
  Log GetLogLevel($name,2), "HMLAN_Parse: $name new condition $HMcndTxt";
  my $txt;
  $txt .= $HMcond{$_}.":".$hashCnd->{$_}." "
                            foreach (keys%{$hashCnd});

  readingsBeginUpdate($hash);
  readingsBulkUpdate($hash,"cond",$HMcndTxt);
  readingsBulkUpdate($hash,"Xmit-Events",$txt);
  readingsBulkUpdate($hash,"prot_".$HMcndTxt,"last");
  readingsEndUpdate($hash,1);

  $hashQ->{HMcndN} = $HMcnd;
  
  if ($HMcnd == 4 || $HMcnd == 253) {#transmission down
    $hashQ->{answerPend} = 0;
	@{$hashQ->{apIDs}} = ();     #clear Q-status
    $hash->{XmitOpen} = 0;         #deny transmit
  }
  elsif ($HMcnd == 255) {#reset counter after init
    $hashQ->{answerPend} = 0;
	@{$hashQ->{apIDs}} = ();     #clear Q-status
    $hash->{XmitOpen} = 1;         #deny transmit
  }
  else{
    $hash->{XmitOpen} = 1 
	    if($hashQ->{answerPend} < $hashQ->{hmLanQlen});#allow transmit
  }	
}

1;

=pod
=begin html

<a name="HMLAN"></a>
<h3>HMLAN</h3>
<ul>
	The HMLAN is the fhem module for the eQ-3 HomeMatic LAN Configurator.<br>
	A description on how to use  <a href="https://git.zerfleddert.de/cgi-bin/gitweb.cgi/hmcfgusb">hmCfgUsb</a> can be found follwing the link.<br/>
	<br/>
	The fhem module will emulate a CUL device, so the <a href="#CUL_HM">CUL_HM</a> module can be used to define HomeMatic devices.<br/>
	<br>
	In order to use it with fhem you <b>must</b> disable the encryption first with the "HomeMatic Lan Interface Configurator"<br>
	(which is part of the supplied Windows software), by selecting the device, "Change IP Settings", and deselect "AES Encrypt Lan Communication".<br/>
	<br/>
	This device can be used in parallel with a CCU and (readonly) with fhem. To do this:
	<ul>
		<li>start the fhem/contrib/tcptee.pl program</li>
		<li>redirect the CCU to the local host</li>
		<li>disable the LAN-Encryption on the CCU for the Lan configurator</li>
		<li>set the dummy attribute for the HMLAN device in fhem</li>
	</ul>
	<br/><br/>

	<a name="HMLANdefine"></a>
	<b>Define</b>
	<ul>
		<code>define &lt;name&gt; HMLAN &lt;ip-address&gt;[:port]</code><br>
		<br>
		port is 1000 by default.<br/>
		If the ip-address is called none, then no device will be opened, so you can experiment without hardware attached.
	</ul>
	<br><br>

	<a name="HMLANset"></a>
	<b>Set</b>
	<ul>
		<li><a href="#hmPairForSec">hmPairForSec</a></li>
		<li><a href="#hmPairSerial">hmPairSerial</a></li>
	</ul>
	<br><br>

	<a name="HMLANget"></a>
	<b>Get</b>
	<ul>
		N/A
	</ul>
	<br><br>

	<a name="HMLANattr"></a>
	<b>Attributes</b>
	<ul>
		<li><a href="#do_not_notify">do_not_notify</a></li><br>
		<li><a href="#attrdummy">dummy</a></li><br>
		<li><a href="#loglevel">loglevel</a></li><br>
		<li><a href="#addvaltrigger">addvaltrigger</a></li><br>
		<li><a href="#hmId">hmId</a></li><br>
		<li><a href="#hmProtocolEvents">hmProtocolEvents</a></li><br>
		<li><a href="#respTime">respTime</a><br>
		Define max response time of the HMLAN adapter in seconds. Default is 1 sec.<br/>
		Longer times may be used as workaround in slow/instable systems or LAN configurations.</li>
		<li><a href="#wdTimer">wdTimer</a><br>
		Time in sec to trigger HMLAN. Values between 5 and 25 are allowed, 25 is default.<br>
		It is <B>not recommended</B> to change this timer. If problems are detected with <br>
		HLMLAN disconnection it is advisable to resolve the root-cause of the problem and not symptoms.</li>
		<li><a href="#hmLanQlen">hmLanQlen</a><br>
		defines queuelength of HMLAN interface. This is therefore the number of 
		simultanously send messages. increasing values may cause higher transmission speed. 
		It may also cause retransmissions up to data loss.<br>
		Effects can be observed by watching protocol events<br>
		1 - is a conservatibe value, and is default<br>
		5 - is critical length, likely cause message loss</li>
	</ul>
</ul>

=end html
=cut
