#############################################
package main;

use strict;
use warnings;
use Device::Firmata;
use Device::Firmata::Constants  qw/ :all /;

#####################################

my %sets = (
  "alarm" => "",
  "count" => 0,
);

my %gets = (
  "reading" => "",
  "state"   => "",
  "count"   => 0,
  "alarm"   => "off"
);

sub
FRM_IN_Initialize($)
{
  my ($hash) = @_;

  $hash->{SetFn}     = "FRM_IN_Set";
  $hash->{GetFn}     = "FRM_IN_Get";
  $hash->{AttrFn}    = "FRM_IN_Attr";
  $hash->{DefFn}     = "FRM_Client_Define";
  $hash->{InitFn}    = "FRM_IN_Init";
  $hash->{UndefFn}   = "FRM_IN_Undef";
  
  $hash->{AttrList}  = "IODev count-mode:none,rising,falling,both count-threshold reset-on-threshold-reached:yes,no internal-pullup:on,off loglevel:0,1,2,3,4,5 $main::readingFnAttributes";
}

sub
FRM_IN_Init($$)
{
	my ($hash,$args) = @_;
	my $ret = FRM_Init_Pin_Client($hash,$args,PIN_INPUT);
	return $ret if (defined $ret);
	eval {
    my $firmata = FRM_Client_FirmataDevice($hash);
    $firmata->observe_digital($hash->{PIN},\&FRM_IN_observer,$hash);
  	if (defined (my $pullup = AttrVal($hash->{NAME},"internal-pullup",undef))) {
  	  $firmata->digital_write($hash->{PIN},$pullup eq "on" ? 1 : 0);
  	}
	};
	return $@ if (defined $@);
	if (! (defined AttrVal($hash->{NAME},"stateFormat",undef))) {
		$main::attr{$hash->{NAME}}{"stateFormat"} = "reading";
	}
	main::readingsSingleUpdate($hash,"state","Initialized",1);
	return undef;
}

sub
FRM_IN_observer
{
	my ($pin,$old,$new,$hash) = @_;
	main::Log(6,"onDigitalMessage for pin ".$pin.", old: ".(defined $old ? $old : "--").", new: ".(defined $new ? $new : "--"));
	my $name = $hash->{NAME};
	my $changed = ((!(defined $old)) or ($old != $new));
	main::readingsBeginUpdate($hash);
	if ($changed) { 
  	if (defined (my $mode = main::AttrVal($name,"count-mode",undef))) {
  		if (($mode eq "both")
  		or (($mode eq "rising") and ($old == PIN_LOW))
  		or (($mode eq "falling") and ($old == PIN_HIGH))) {
  	    	my $count = main::ReadingsVal($name,"count",0);
  	    	$count++;
  	    	if (defined (my $threshold = main::AttrVal($name,"count-threshold",undef))) {
  	    		if ( $count > $threshold ) {
  	    			if (AttrVal($name,"reset-on-threshold-reached","no") eq "yes") {
  	    			  $count=0;
  	    			  main::readingsBulkUpdate($hash,"alarm","on",1);
  	    			} elsif ( main::ReadingsVal($name,"alarm","off") ne "on" ) {
  	    			  main::readingsBulkUpdate($hash,"alarm","on",1);
  	    			}
  	    		}
  	    	}
  	    	main::readingsBulkUpdate($hash,"count",$count,1);
  	    } 
  	};
	}
	main::readingsBulkUpdate($hash,"reading",$new == PIN_HIGH ? "on" : "off", $changed);
	main::readingsEndUpdate($hash,1);
}

sub
FRM_IN_Set
{
  my ($hash, @a) = @_;
  return "Need at least one parameters" if(@a < 2);
  return "Unknown argument $a[1], choose one of " . join(" ", sort keys %sets)
  	if(!defined($sets{$a[1]}));
  my $command = $a[1];
  my $value = $a[2];
  COMMAND_HANDLER: {
    $command eq "alarm" and do {
      return undef if (!($value eq "off" or $value eq "on"));
      main::readingsSingleUpdate($hash,"alarm",$value,1);
      last;
    };
    $command eq "count" and do {
      main::readingsSingleUpdate($hash,"count",$value,1);
      last;
    };
  }
}

sub
FRM_IN_Get($)
{
  my ($hash, @a) = @_;
  return "Need at least one parameters" if(@a < 2);
  return "Unknown argument $a[1], choose one of " . join(" ", sort keys %gets)
  	if(!defined($gets{$a[1]}));
  my $name = shift @a;
  my $cmd = shift @a;
  ARGUMENT_HANDLER: {
    $cmd eq "reading" and do {
      eval {
        return FRM_Client_FirmataDevice($hash)->digital_read($hash->{PIN}) == PIN_HIGH ? "on" : "off";
      };
      return $@;
    };
    ( $cmd eq "count" or $cmd eq "alarm" or $cmd eq "state" ) and do {
      return main::ReadingsVal($name,"count",$gets{$cmd});
    };
  }
  return undef;
}

sub
FRM_IN_Attr($$$$) {
  my ($command,$name,$attribute,$value) = @_;
  if ($command eq "set") {
    ARGUMENT_HANDLER: {
      $attribute eq "count-mode" and do {
        if ($value ne "none" and !defined main::ReadingsVal($name,"count",undef)) {
          main::readingsSingleUpdate($main::defs{$name},"count",$sets{count},1);
        }
        last;
      }; 
      $attribute eq "reset-on-threshold-reached" and do {
        if ($value eq "yes"
        and defined (my $threshold = main::AttrVal($name,"count-threshold",undef))) {
          if (main::ReadingsVal($name,"count",0) > $threshold) {
            main::readingsSingleUpdate($main::defs{$name},"count",$sets{count},1);
          }
        }
        last;
      };
      $attribute eq "count-threshold" and do {
        if (main::ReadingsVal($name,"count",0) > $value) {
          my $hash = $main::defs{$name};
          main::readingsBeginUpdate($hash);
          if (main::ReadingsVal($name,"alarm","off") ne "on") {
            main::readingsBulkUpdate($hash,"alarm","on",1);
          }
          if (main::AttrVal($name,"reset-on-threshold-reached","no") eq "yes") {
            main::readingsBulkUpdate($main::defs{$name},"count",0,1);
          }
          main::readingsEndUpdate($hash,1);
        }
        last;
      };
      $attribute eq "internal-pullup" and do {
      	eval {
          my $hash = $main::defs{$name};
          my $firmata = FRM_Client_FirmataDevice($hash);
          $firmata->digital_write($hash->{PIN},$value eq "on" ? 1 : 0);
      	};
      	#ignore any errors here, the attribute-value will be applied next time FRM_IN_init() is called.
      	last;
      };  
    }
  } elsif ($command eq "del") {
    ARGUMENT_HANDLER: {
      $attribute eq "internal-pullup" and do {
      	eval {
          my $hash = $main::defs{$name};
          my $firmata = FRM_Client_FirmataDevice($hash);
          $firmata->digital_write($hash->{PIN},0);
      	};
        last;
      };
    }
  }
}

sub
FRM_IN_Undef($$)
{
  my ($hash, $name) = @_;
}

1;

=pod
=begin html

<a name="FRM_IN"></a>
<h3>FRM_IN</h3>
<ul>
  represents a pin of an <a href="http://www.arduino.cc">Arduino</a> running <a href="http://www.firmata.org">Firmata</a>
  configured for digital input.<br>
  The current state of the arduino-pin is stored in reading 'state'. Values are 'on' and 'off'.<br>
  Requires a defined <a href="#FRM">FRM</a>-device to work.<br><br> 
  
  <a name="FRM_INdefine"></a>
  <b>Define</b>
  <ul>
  <code>define &lt;name&gt; FRM_IN &lt;pin&gt;</code> <br>
  Defines the FRM_IN device. &lt;pin&gt> is the arduino-pin to use.
  </ul>
  
  <br>
  <a name="FRM_INset"></a>
  <b>Set</b><br>
  <ul>
    <li>alarm on|off<br>
    set the alarm to on or off. Used to clear the alarm.<br>
    The alarm is set to 'on' whenever the count reaches the threshold and doesn't clear itself.</li>
  </ul>
  <a name="FRM_INget"></a>
  <b>Get</b>
  <ul>
    <li>reading<br>
    returns the logical state of the arduino-pin. Values are 'on' and 'off'.<br></li>
    <li>count<br>
    returns the current count. Contains the number of toggles of the arduino-pin.<br>
    Depending on the attribute 'count-mode' every rising or falling edge (or both) is counted.</li>
    <li>alarm<br>
    returns the current state of 'alarm'. Values are 'on' and 'off' (Defaults to 'off')<br>
    'alarm' doesn't clear itself, has to be set to 'off' eplicitly.</li>
    <li>state<br>
    returns the 'state' reading</li>
  </ul><br>
  <a name="FRM_INattr"></a>
  <b>Attributes</b><br>
  <ul>
      <li>count-mode none|rising|falling|both<br>
      Determines whether 'rising' (transitions from 'off' to 'on') of falling (transitions from 'on' to 'off')<br>
      edges (or 'both') are counted. Defaults to 'none'</li>
      <li>count-threshold &lt;number&gt;<br>
      sets the theshold-value for the counter. Whenever 'count' reaches the 'count-threshold' 'alarm' is<br>
      set to 'on'. Use 'set alarm off' to clear the alarm.</li>
      <li>reset-on-threshold-reached yes|no<br>
      if set to 'yes' reset the counter to 0 when the threshold is reached (defaults to 'no').
      </li>
      <li>internal-pullup on|off<br>
      allows to switch the internal pullup resistor of arduino to be en-/disabled. Defaults to off.
      </li>
      <li><a href="#IODev">IODev</a><br>
      Specify which <a href="#FRM">FRM</a> to use. (Optional, only required if there is more
      than one FRM-device defined.)
      </li>
      <li><a href="#eventMap">eventMap</a><br></li>
      <li><a href="#readingFnAttributes">readingFnAttributes</a><br></li>
    </ul>
  </ul>
<br>

=end html
=cut
