#!/usr/bin/perl -w

# https://github.com/veksh/CGPro_checkfrom

# run `perldoc check_from.pl` for documentation (or see POD at the end of file)

use strict;
use FileHandle;
use CLI;

## title to report
my $progTitle = 'check_from';
## global config
my $conf;
## global config defaults
my $defaults = {
  serverAddress => '127.0.0.1',
  serverPort    => 106,
  userName      => 'postmaster',
  userPassword  => 'verysecret',
  debugLevel    => 'WARN',
  failOpen      => 1,
  trimDomain    => 1,
  moveDomain    => 0,
  allowBounce   => 0,
  allowRules    => 1,
};

## request ID; local for forked request processor
my $reqID = 0;

## daemonization setup
$SIG{CHLD}='IGNORE';
$SIG{__DIE__}  = \&reportAndDie;
$| = 1;

# read vales from simple config, optionally assign defaults for missed ones
# - config format: usual 'key = value', lines starting with '#' are comments, blanks ok
# - defaults: hash reference, copied before use
# - returns another hash reference with 'key' => 'value' pairs from config file merged
sub readConfig {
  my $fileName = shift || die 'no config name given';
  my $defaults = shift || {};

  return undef unless $fileName;

  my $conf = { %$defaults };
  my $FH = FileHandle->new($fileName, "r") || die "could not open config $fileName: $!";

  while (my $line = <$FH>) {
    next if $line =~ /^#/ || $line =~ /^\s*$/;
    chomp $line;
    my ($param, $val) = ($line =~ /(\S+)\s+=\s+(.*)$/);
    $conf->{$param} = $val;
  }
  $FH->close();
  return $conf;
}

## return reply to CommuniGate in "<seqNum> <REPLY> [<text>]" format
# - depending on level, it prints either
#   - debug output (of different severity): LOG_LEVEL keys
#     - global debugLevel specifies lower threshold of output for pure debug
#   - actual command to CommuniGate (pass/discard): REPLY_LEVEL keys
#     - some messages like 'DISCARD' are log-less for CommuniGate, so log statements
#       are added to compensate
# - progTitle is prepended to message text
# - seqNum is implicit $reqID global var, set befor fork()'ing checker process
sub reply {
  my $level = shift || 'WARN';
  my $msg   = shift || '';

  my $LOG_LEVEL = { 
    'SKIP'  => -1,
    'DEBUG' => 1, 
    'INFO'  => 2,
    'NOTE'  => 3,
    'WARN'  => 4,
    'CRIT'  => 5,
    'FATAL' => 6 };
  # some reply types are generating logs themself, for some addl text is needed
  my $REPLY_LEVEL = {
    'OK'      => 'INFO',
    'ERROR'   => 'SKIP',
    'DISCARD' => 'NOTE',
    'REJECT'  => 'SKIP',
    'FAILURE' => 'SKIP',
  };

  my $debugLevel = $conf->{'debugLevel'} || 'WARN';
  $level = 'WARN' unless $LOG_LEVEL->{$level} || $REPLY_LEVEL->{$level};  
  if ($LOG_LEVEL->{$level}) {
    # pure debug message: add to log
    return if $LOG_LEVEL->{$level} < $LOG_LEVEL->{$debugLevel};
    #print "* $reqID $level $progTitle $msg\n";
    print "* $reqID $level $msg\n";
  } else {
    # reply
    if (! $msg) {
      # just say it
      print "$reqID $level\n";
    } else {
      # add separate debug output if REPLY_LEVEL is not SKIP
      my $msgLevel = $REPLY_LEVEL->{$level};
      if ($msgLevel eq 'SKIP') {
        # include debug in message
        my $msgQ = $msg;
        $msgQ =~ s/"/\"/g;
        print "$reqID $level \"$msgQ\"\n";
      } else {
        # additional debug line if allowed
        if ($LOG_LEVEL->{$msgLevel} >= $LOG_LEVEL->{$debugLevel}) {
          #print "* $reqID $msgLevel $progTitle $msg\n";
          print "* $reqID $msgLevel $msg\n";
        }
        # reply itself
        print "$reqID $level\n";
      }
    }
  }
}

## depending on failOpen config var, return either 'PASS/FAIL' or 'REJECT/FAIL' 
sub replyFail {
  my $msg = shift || '';

  if ($conf->{'failOpen'}) {
    reply('FAILURE', $msg);
  } else {
    reply('ERROR', $msg);
  }
}

## die after writing death note to log
sub reportAndDie {
  my $deathNote = shift;

  return if $^S;
  chomp $deathNote;
  reply('FAILURE', "exiting on internal error: $deathNote");
  exit 1;
}

## check msg file
sub processFile {
  my $fileName = shift;

  unless (open FILE, "<$fileName") {
    replyFail("cannot open $fileName: $!");
    return undef;
  }

  # from cgpav-1.5 sources: header format
  # the header of the message file, P - sender, R - recipient, S - SMTP server
  #   P I 17-09-2001 09:52:33 0000 ____ ____ <ann@domain.ru>
  #   O T
  #   S SMTP [199.199.199.199]
  #   R W 17-09-2001 09:52:33 0000 ____ _FY_ <nif@guga.ru>
  #   R W 17-09-2001 09:52:33 0000 ____ _FY_ <naf@buki.ru>
  #   (empty line)
  # actual message sample
  #   A mt.company.com
  #   S HTTP [10.1.11.6]
  #   P I 13-04-2012 16:17:43 0000 ____ ____ <alice@mt.company.com>
  #   O L
  #   R W 13-04-2012 16:17:43 0000 ____ _FY_ <bob@mt.company.com>
  # or for pronto-generated message
  #   S HTTPU [10.1.11.6]
  #   A company.com
  #   O L
  #   P I 10-04-2013 11:22:43 0000 ____ ____ <alex@company.com>
  #   R W 10-04-2013 11:22:43 0000 ____ _FY_ <knjaz@company.com>
  # or for bounce with web user interface
  #   P I 25-03-2013 08:34:46 0000 ____ ____ <alice@mt.company.com>
  #   O L
  #   S WEBUSER [0.0.0.0]
  #   A mt.company.com
  #   R W 25-03-2013 08:34:46 0000 ____ _FY_ <alex@mt.company.com>
  # or for undeliverable/DSN report to postmaster
  #   P I 25-03-2013 12:52:22 0000 ____ ____ <>
  #   O L
  #   S DSN [0.0.0.0]
  #   R W 25-03-2013 12:52:22 0000 ____ ____ <alice@mt.company.com>
  #   R W 25-03-2013 12:52:22 0000 ____ ____ <postmaster>
  # or for rule-generated message  
  #   P I 25-03-2013 12:52:22 0000 ____ ____ <>
  #   O L
  #   S RULE [0.0.0.0]
  #   A drone.m1.company.com
  #   R W 25-03-2013 12:52:22 0000 ____ ____ <alex@mt.company.com>
  # or for rule-generated bounce (vacation redirect; also has 'X-Autogenerated: Redirect' header)
  #   S RULE [0.0.0.0]
  #   A company.com
  #   O L
  #   P I 10-04-2013 11:22:43 0000 ____ ____ <knjaz@company.com>
  #   R W 10-04-2013 11:22:43 0000 ____ ____ <some.name@gmail.com>
  # or for calendar alarm
  #   P I 26-03-2013 05:12:00 0000 ____ ____ <>
  #   R W 26-03-2013 05:12:00 0000 ____ _F__ <max@mt.company.com>
  #   O LH
  #   S ALARM [0.0.0.0]
  # meaining of some fields is unclear but not importaint for us

  # extract envelope information
  my ($envSender, $envSenderProto, $envSenderIP, @recipients);
  while (my $line = <FILE>) {
    chomp($line);
    reply('DEBUG', "envelope: got line $line");
    last if $line eq '';
    if ($line =~ /^(\w).+<(.*)>$/) {
      if ($1 eq 'P') { 
        $envSender = $2 || '(empty)';
      } elsif ($1 eq 'R') {
        push(@recipients, $2);
      }
    } elsif ($line =~ /^S (\S+) \[(.+)\]$/) {
      $envSenderProto = $1;
      $envSenderIP = $2;
    }
  }

  if ($envSender) {
    reply('INFO', "found envelope From: <$envSender>");
  } else {
    replyFail('envelope sender missing');
    return 0;
  }

  if ($envSender eq '(empty)') {
    reply('OK', "service message with empty env sender, passing");
    return 1;
  }

  # parse headers; first match wins
  my ($authSenderIP, $authName, $authDomain, $authSender, $headersSender, $someFrom, $messageId, $origMessageId);
  while (my $line = <FILE>) {
    chomp($line);
    last if $line eq '';
    reply('DEBUG', "headers: got line $line");
    if (! $authName && $line =~ /^Sender: <(\S+)\@(\S+)>/) {
      # Sender: <alice@mt.company.com>
      ($authName, $authDomain) = ($1, $2);
      $authSender = "$authName\@$authDomain";
      reply('DEBUG', "found auth sender <$authSender>");
    } elsif (! $authName && $line =~ /^Received: from \[(\S+)\] \(account (\S+)\@([^) ]+)/) {
      # like "Received: from [10.1.11.6] (account alice@mt.company.com)"
      # or "Received: from [194.85.103.16] (account pot@company.com HELO pot)"
      ($authSenderIP, $authName, $authDomain) = ($1, $2, $3);
      $authSender = "$authName\@$authDomain";
      reply('DEBUG', "found auth sender <$authSender>");
    } elsif (!$headersSender && $line =~ /^From: /) {
      $someFrom = 1;
      if ($line =~ /From: (?!<)(\S+\@\S+)$/) {
        # From: root@drone.m1.company.com
        $headersSender = $1;
        reply('DEBUG', "headers: got line $line");
        reply('DEBUG', "found headers sender <$headersSender>");
      } else {
        # From: "=?utf-8?B?0JDQu9C40YHQsA==?=
        #  =?utf-8?B?INCi0LXRgdGC0L7QstCw0Y8=?="
        #  <alice@mt.company.com>
        # From:  "=?utf-8?B?0JDQu9C10LrRgdC10Lk=?=
        #  =?utf-8?B?INCS0LXQutGI0LjQvQ==?=" <alex@company.com>
        # may be split; lets read continuation right here
        while ($line !~ / <([^>]+)>$/) {
          $line = <FILE>;
          chomp($line);
          last if $line !~ /^ /;
          reply('DEBUG', "headers: got line $line");
        }
        if ($line =~ / <([^>]+)>$/) {
          $headersSender = $1;
          reply('DEBUG', "found headers sender <$headersSender>");
        }
      }
    } elsif (!$messageId && $line =~ /^Message-I[Dd]: <([^>]+)>/) {
      # Message-ID: <web-101261@drone.m1.company.com>
      $messageId = $1;
      reply('DEBUG', "found msg id <$messageId>");
    } elsif (!$origMessageId && $line =~ /^X-Original-Message-I[Dd]: <([^>]+)>/) {
      # X-Original-Message-Id: <98C5B147-8BA9-4359-81F4-79AA149610A8@company.com
      $origMessageId = $1;
      reply('DEBUG', "found original msg id <$origMessageId>");
    }
  }
  close FILE;

  if (! $authSender) {
    reply('OK', "message w/o authentication data, passing");
    return 1;
  } else {
    reply('INFO', "sender auth name '$authSender'");
  }

  if ($headersSender) {
    reply('INFO', "header From: <$headersSender>");
  } else {
    if ($someFrom) {
      reply('WARN', 'malformed From header');
      replyFail('header malformed: From');
    } else {
      reply('WARN', 'missed From header');
      replyFail('header missing: From');
    }
    return 0;
  }
  if ($messageId) {
    reply('INFO', "header MsgID: <$messageId>");
  } else {
    reply('WARN', 'header MsgID not found (bad format?)');
    replyFail('header missing: MessageId');
    return 0;
  }

  # check: simple match
  my $safe = 0;
  if ($origMessageId && $headersSender && $authName) {
    if ($conf->{'allowBounce'}) {
      reply('OK', "allowed bounced message from $authName (orig $headersSender)");
      return 1;
    } elsif ($conf->{'allowRules'} && $envSenderProto eq 'RULE') {
      reply('OK', "allowed rule redirect from $authName (orig $headersSender)");
      return 1;
    }
  }

  if (lc($envSender) ne lc($headersSender)) {
    reply('WARN', "'From' mismatch (headers '$headersSender', envelope '$envSender'), mid <$messageId>");
  }
  if (lc($authSender) eq lc($headersSender)) {
    reply('OK', 'auth and headers sender match, passing');
    return 1;
  }

  # try simple transformations if permitted by config
  if ($conf->{'trimDomain'} || $conf->{'moveDomain'}) {
    my ($name, $d_first, $d_rest) = ($authSender =~ /^([^@]+)\@([^.]+)\.(.*)$/);
    if ($name && $d_first && $d_rest) {
      if ($conf->{'trimDomain'} && (lc($headersSender) eq lc("$name\@$d_rest"))) {
        reply('OK', 'auth and headers sender match after trim, passing');
        return 1;
      }
      if ($conf->{'moveDomain'} && (lc($headersSender) eq lc("$name-$d_first\@$d_rest"))) {
        reply('OK', 'auth and headers sender match after trim and move, passing');
        return 1;
      }
    }
  }

  # check: aliases
  my $cli = new CGP::CLI( { PeerAddr => $conf->{'serverAddress'},
                            PeerPort => $conf->{'serverPort'},
                            login    => $conf->{'userName'},
                            password => $conf->{'userPass'} } );
  if (! $cli) {
    replyFail("cannot login to server via CLI: " . $CGP::ERR_STRING);
    return 0;
  }
    
  my $numAlts = 0;
  my @alts;
  my $aliases = $cli->GetAccountAliases($authSender);
  my $aliasesFound = 0;
  foreach my $alias (@$aliases) {
    my $fullAliasAddress = $alias . '@' . $authDomain;
    reply('DEBUG', "got alias $fullAliasAddress");
    if (lc($headersSender) eq lc($fullAliasAddress)) {
      reply('OK', "found matching alias $fullAliasAddress");
      $cli->Logout();
      return 1;
    } else {
      $numAlts += 1;
      push(@alts, $fullAliasAddress);
    }
  }
  reply('DEBUG', "no aliases for $authSender found") unless $aliasesFound;
  #my $forwarders = $cli->FindForwarders($authDomain, $authSender);
  my $forwarders = $cli->FindForwarders($authDomain, $authName);
  my $forwardersFound = 0;
  foreach my $forwarder (@$forwarders) {
    my $fullForwarderAddress = $forwarder . '@' . $authDomain;
    reply('DEBUG', "got forwarder $fullForwarderAddress");
    if (lc($headersSender) eq lc($fullForwarderAddress)) {
      reply('OK', "found matching forwarder $fullForwarderAddress");
      $cli->Logout();
      return 1;
    } else {
      $numAlts += 1;
      push(@alts, $fullForwarderAddress);
    }
  }
  reply('DEBUG', "no forwarders for $authName in $authDomain found") unless $forwardersFound;
  reply('INFO', "found $numAlts wrong adresses: " . join(', ', @alts)) if $numAlts;

  $cli->Logout();
  reply('ERROR', "'From' address not allowed (user '$authSender', address '$headersSender'), dropping message");
}

## main

# the only arg is config name
my $confFileName = $ARGV[0] || '/usr/local/etc/' . $progTitle . '.conf';
$conf = readConfig($confFileName, $defaults);

reply('NOTE', 'Starting');

while (my $line = <STDIN>) {
  chomp($line);
  if ($line !~ /^\d+ \S+/) {
    reply("FAILURE", "cannot parse line '$line'");
    next;
  }
  my ($seqNo, $command, @args) = split(/ /, $line);
  $reqID = $seqNo;
  reply('DEBUG', "command = $command, args = '@args'");
  if ($command eq 'INTF') { 
    print "$reqID INTF 3\n";
  } elsif ($command eq 'KEY') { 
    print "$reqID OK\n";
  } elsif ($command eq 'QUIT') {
    reply('NOTE', "Exiting");
    reply('OK', "Quit command received");
    exit 0;
  } elsif ($command eq 'FILE') {
    my $fileName = $args[0];
    reply('INFO', "processing '$fileName'");
    my $pid = fork();
    if (!defined($pid)) {
      my $err = "$!";
      reportAndDie("cannot fork(): error $err");
    } elsif ($pid == 0) {
      processFile($fileName);
      exit;
    }
  } else {
    reply('FAILURE', "unexpected command: '$command'");
  }
}

__END__

=pod

=head1 NAME

check_from.pl - CommuniGate Pro helper plugin to check if "From" address allowed for user.

=head1 SYNOPSIS

B<check_from.pl> [I<config_file_name>]

The only option for now is config file name (default C</usr/local/etc/check_from.cnf>)

=head1 DESCRIPTION

=head2 Modus Operandi

This program intended to be called from Communigate as external filter process.
For each submitted message, it extracts from temporary file

=over 4

=item *
envelope "From" address.

=item *
headers "From" address.

=item *
name used in SMTP AUTH.

=item *
original "From" address (for bounced messages).

=back

Both "From" addresses must be equal (overwise warning is logged and envelope "From" is used
in later checks). If SMTP AUTH name could not be found message is assumed to be from safe source
(locally submitted, external peers, upstream relay).

In simplest case, "From" address equals "SMTP AUTH" account name, and message passes check.
Using alias as login name is OK too, CommuniGate will put main account name in AUTH headers anyway.

For bounced messages (i.e. re-sent to a new recipients not as an attachment/quote/forward, but as 
a clone of an original message with some fields and in some cases even body of message altered), 
"From" address is usually wrong (does not match re-sender auth name). In this case message action 
is determined by "allowBounce" global param. By default it is turned off because bounced messages 
are highly misleading and usually produced by clueless users, but one could allow to bounce 
messages this way if users are educated enough and client cleanly shows message as forwarded
(e.g. Apple Mail displays "Resent-From:" header above usual ones and is OK).

Another popular source of bounces is automated rules (simple rule "Redirect All Mail To"), which
is enabled by default and could be turned off by setting "allowRules" param to "false" in config.

For non-bounced messages 2 simple transformations are tried (depending on "trimDomain" and 
"moveDomain" config params):

=over 4

=item * I<trimDomain>
trim leftmost part of domain: "vasia@mt.company.com" would pass for "vasia@company.com".

=item * I<moveDomain>
move leftmost part of domain to name: "vasia@mt.company.com" could use "vasia-mt@company.com".

=back 

For now, those would be performed only for "simple" match.

If "From" address is still different from account name, filter connects to CommuniGate with CCI and 
gets lists of other allowed "From" addresses:

=over 4

=item * account aliases: 
those are alternative names for account.

=item * account forwarders:
those are separate routing records, pointing to user account.

=back

If "From" address is in one of those lists, message passes check. Otherwise, "From" address considered 
forged and "ERROR" is returned to CommuniGate to reject message.

=head2 Reaction to errors

If required fields could not be found in message is either passed or rejected depending on I<failOpen> 
configuration parameter.

=head2 Logging

Operational errors and rejected messages are logged to CommuniGate log as usual.
Additional operational details are logged if I<verbose> parameter is specified in configuration.

To view program debug logs, set log level to "All Info" in "Helpers" settings.

=head1 CONFIGURATION AND ENVIRONMENT

=head2 Configuration

Parameters in config file are as follows:

=over 4

=item * I<serverAddress>:
address of CommuniGate server to check users againtst, default "localhost"

=item * I<serverPort>:
port for PWD access, default 106

=item * I<userName>:
slightly-privileged user, default "postmaster"

=item * I<userPass>:
passsword for userName, no default

=item * I<debugLevel>:
level of debug output from filter: one of C<DEBUG>, C<INFO>, C<NOTE>, C<WARN>, C<CRIT>,
default I<WARN>

=item * I<failOpen>:
on some configuration or processing faulure, pass messages (1) or return error (0), 
default is to pass 

=back

=head2 CommuniGate integration

Program must be configured as CommuniGate content filter helper as usual.
To use it call filter from some domain-wide (or for some subset of users) rule like

=over 4 

=item B<condition>:
C<'Source' 'in' 'authenticated'> 

=item B<action>:
C<'ExternalFilter' 'check_from'>

=back

Account used to connect to CommuniGate (specified in config) must have "Basic Settings" access right for 
domains (commands FINDFORWARDERS and GETACCOUNTALIASES allowed in CLI); as an unfortunate side effect it 
gives this user write access to some settings, so keep password secure and PWD access local. 

To grant user global access, create it like this:

=over 4

=item * create user in main server domain (usually only "pbx" and "postmaster" are there)

=item * on "Access Rights" page, check "Can Modify This Domain", press "Update"

=item * check some unimportaint privilege like "Call Info" plus "Can Administer Other Domains", 
        press "Updatge"

=item * in each target domain setting, enter main server domain as "Administrator Domain"

=back 

To test for sufficient access level, do something like this while logged as target user in CLI

=over 4

=item * GETACCOUNTALIASES alice@mt.company.com

=item * FINDFORWARDERS mt.company.com TO alice@mt.company.com

=back

To restrict access from non-localhost addresess, uncheck "Mobile" service in "Enabled Services" for
this account (actually, it is better to live only PWD access enabled).

=head1 DEPENDENCIES

Requires C<CGI.pm> from L<CommuniGate site|http://www.communigate.com/CGPerl/>.

=head1 BUGS AND LIMITATIONS

Probably present.

Script does not check for CommuniGate "Router" records and groups/lists (support for lists would be
relatively easy to add, maybe i'll add some for the next version).

Also worth adding: record aliases like "name+box@dom.com".

Whole global "moveDomain"/"trimDomain" hack is wrong: actually, there will be no need for that if
proper split domain would be implemented and all "From" addresses would be known, but for now it is
a good way to allow partial sub-domains with some amount of "From" checking.

Maybe some way to specify additional allowed "from" addresses would be userful, but I cannot think
about one at the time (user datasets?).

Anonymous LDAP would probably be better but currently it could not be used to check mails because 
CommuniGate does not expose aliases to LDAP, and forwarders information is not sufficient to determine 
destination.

=head1 AUTHOR

S<Alexey Vekshin E<lt>alex(at)maxidom.ruE<gt>>

=cut
