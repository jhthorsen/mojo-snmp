package Mojo::SNMP;

=head1 NAME

Mojo::SNMP - Run SNMP requests with Mojo::IOLoop

=head1 VERSION

0.07

=head1 SYNOPSIS

  use Mojo::SNMP;
  my $snmp = Mojo::SNMP->new;
  my @response;

  $snmp->on(response => sub {
    my($snmp, $session, $args) = @_;
    warn "Got response from $args->{hostname} on $args->{method}(@{$args->{request}})...\n";
    push @response, $session->var_bind_list;
  });

  $snmp->defaults({
    community => 'public', # v1, v2c
    username => 'foo', # v3
    version => 'v2c', # v1, v2c or v3
  });

  $snmp->prepare('127.0.0.1', get_next => ['1.3.6.1.2.1.1.3.0']);
  $snmp->prepare('localhost', { version => 'v3' }, get => ['1.3.6.1.2.1.1.3.0']);

  # start the IOLoop unless it is already running
  $snmp->wait unless $snmp->ioloop->is_running;

=head1 DESCRIPTION

You should use this module if you need to fetch data from many SNMP servers
really fast. The module does its best to not get in your way, but rather
provide a simple API which allow you to extract information from multiple
servers at the same time.

This module use L<Net::SNMP> and L<Mojo::IOLoop> to fetch data from hosts
asynchronous. It does this by using a custom dispatcher,
L<Mojo::SNMP::Dispatcher>, which attach the sockets created by L<Net::SNMP>
directly into the ioloop reactor.

If you want greater speed, you should check out L<Net::SNMP::XS> and make sure
L<Mojo::Reactor::EV> is able to load.

L<Mojo::SNMP> is supposed to be a replacement for a module I wrote earlier,
called L<SNMP::Effective>. Reason for the rewrite is that I'm using the
framework L<Mojolicious> which includes an awesome IO loop which allow me to
do cool stuff inside my web server.

=head1 CUSTOM SNMP REQUEST METHODS

L<Net::SNMP> provide methods to retrieve data from the SNMP agent, such as
L<get_next()|Net::SNMP/get_next>. It is possible to add custom methods if
you find yourself doing the same complicated logic over and over again.
Such methods can be added using L</add_custom_request_method>.

There are two custom methods bundled to this package:

=over 4

=item * bulk_walk

This method will run C<get_bulk_request> until it receives an oid which does
not match the base OID. maxrepetitions is set to 10 by default, but could be
overrided by maxrepetitions inside C<%args>.

Example:

  $self->prepare('192.168.0.1' => { maxrepetitions => 25 }, bulk_walk => [$oid, ...]);

=item * walk

This method will run C<get_next_request> until the next oid retrieved does
not match the base OID or if the tree is exhausted.

=back

=cut

use Mojo::Base 'Mojo::EventEmitter';
use Mojo::IOLoop;
use Mojo::SNMP::Dispatcher;
use Net::SNMP ();
use Scalar::Util ();
use constant DEBUG => $ENV{MOJO_SNMP_DEBUG} ? 1 : 0;
use constant MAXREPETITIONS => 10;

our $VERSION = '0.07';

my @EXCLUDE_METHOD_ARGS = qw( maxrepetitions );
my %EXCLUDE = (
  v1 => [qw/ username authkey authpassword authprotocol privkey privpassword privprotocol /],
  v2c => [qw/ username authkey authpassword authprotocol privkey privpassword privprotocol /],
  v3 => [qw/ community /],
);

my %SNMP_METHOD;
__PACKAGE__->add_custom_request_method(bulk_walk => sub {
  my($session, %args) = @_;
  my $base_oid = $args{varbindlist}[0];
  my $last = $args{callback};
  my $maxrepetitions = $args{maxrepetitions} || MAXREPETITIONS;
  my($callback, $end, %tree, %types);

  $end = sub {
    $session->{_pdu}->var_bind_list(\%tree, \%types) if %tree;
    $session->$last;
    $end = $callback = undef;
  };

  $callback = sub {
      my($session) = @_;
      my $res = $session->var_bind_list or return $end->();
      my @sortres = $session->var_bind_names() or return $end->();
      my $types = $session->var_bind_types;
      my $next = $sortres[-1];

      for my $oid (@sortres) {
          return $end->() unless Net::SNMP::oid_base_match($base_oid, $oid);
          $types{$oid} = $types->{$oid};
          $tree{$oid} = $res->{$oid};
      }

      return $end->() unless $next;
      return $session->get_bulk_request(maxrepetitions => $maxrepetitions, varbindlist => [$next], callback => $callback);
  };

  $session->get_bulk_request(maxrepetitions => $maxrepetitions, varbindlist => [$base_oid], callback => $callback);
});

__PACKAGE__->add_custom_request_method(walk => sub {
  my($session, %args) = @_;
  my $base_oid = $args{varbindlist}[0];
  my $last = $args{callback};
  my($callback, $end, %tree, %types);

  $end = sub {
    $session->{_pdu}->var_bind_list(\%tree, \%types) if %tree;
    $session->$last;
    $end = $callback = undef;
  };

  $callback = sub {
    my($session) = @_;
    my $res = $session->var_bind_list or return $end->();
    my $types = $session->var_bind_types;
    my @next;

    for my $oid (keys %$res) {
      if(Net::SNMP::oid_base_match($base_oid, $oid)) {
        $types{$oid} = $types->{$oid};
        $tree{$oid} = $res->{$oid};
        push @next, $oid;
      }
    }

    return $end->() unless @next;
    return $session->get_next_request(varbindlist => \@next, callback => $callback);
  };

  $session->get_next_request(varbindlist => [$base_oid], callback => $callback);
});

$Net::SNMP::DISPATCHER = $Net::SNMP::DISPATCHER; # avoid warning

=head1 EVENTS

=head2 error

  $self->on(error => sub {
    my($self, $str, $session, $args) = @_;
  });

Emitted on errors which may occur. C<$session> is set if the error is a result
of a L<Net::SNMP> method, such as L<get_request()|Net::SNMP/get_request>.

See L</response> for C<$args> description.

=head2 finish

  $self->on(finish => sub {
    my $self = shift;
  });

Emitted when all hosts have completed.

=head2 response

  $self->on(response => sub {
    my($self, $session, $args) = @_;
  });

Called each time a host responds. The C<$session> is the current L<Net::SNMP>
object. C<$args> is a hash ref with the arguments given to L</prepare>, with
some additional information:

  {
    method => $str, # get, get_next, ...
    request => [$oid, ...],
    # ...
  }

=head2 timeout

  $self->on(timeout => sub {
    my $self = shift;
  })

Emitted if L<wait> has been running for more than L</master_timeout> seconds.

=head1 ATTRIBUTES

=head2 concurrent

How many hosts to fetch data from at once. Default is 20. (The default may
change in later versions)

=head2 defaults

This attribute holds a hash ref with default arguments which will be passed
on to L<Net::SNMP/session>. User-submitted C<%args> will be merged with the
defaults before being submitted to L</prepare>. C<prepare()> will filter out
and ignore arguments that don't work for the SNMP C<version>.

NOTE: SNMP version will default to "v2c".

=head2 master_timeout

How long to run in total before timeout. Note: This is NOT per host but for
the complete run. Default is 0, meaning run for as long as you have to.

=head2 ioloop

Holds an instance of L<Mojo::IOLoop>.

=cut

has concurrent => 20;
has defaults => sub { +{} };
has master_timeout => 0;
has ioloop => sub { Mojo::IOLoop->singleton };

# these attributes are experimental and therefore not exposed. Let me know if
# you use them...
has _dispatcher => sub { Mojo::SNMP::Dispatcher->new(ioloop => $_[0]->ioloop) };
has _pool => sub { +{} };
has _queue => sub { +[] };

=head1 METHODS

=head2 get

  $self->get($host, $args, \@oids, sub {
    my($self, $err, $res) = @_;
    # ...
  });

Will call the callback when data is retrieved, instead of emitting the
L</response> event.

=head2 get_bulk

  $self->get_bulk($host, $args, \@oids, sub {
    my($self, $err, $res) = @_;
    # ...
  });

Will call the callback when data is retrieved, instead of emitting the
L</response> event. C<$args> is optional.

=head2 get_next

  $self->get_next($host, $args, \@oids, sub {
    my($self, $err, $res) = @_;
    # ...
  });

Will call the callback when data is retrieved, instead of emitting the
L</response> event. C<$args> is optional.

=head2 set

  $self->set($host, $args => [ $oid => OCTET_STRING, $value, ... ], sub {
    my($self, $err, $res) = @_;
    # ...
  });

Will call the callback when data is set, instead of emitting the
L</response> event. C<$args> is optional.

=head2 walk

  $self->walk($host, $args, \@oids, sub {
    my($self, $err, $res) = @_;
    # ...
  });

Will call the callback when data is retrieved, instead of emitting the
L</response> event. C<$args> is optional.

=cut

for my $method (qw/ get get_bulk get_next set walk /) {
  eval <<"  CODE" or die $@;
    sub $method {
      my(\$self, \$host) = (shift, shift);
      my \$args = ref \$_[0] eq 'HASH' ? shift : {};
      \$self->prepare(\$host, \$args, $method => \@_);
    }
    1;
  CODE
}

=head2 prepare

  $self = $self->prepare($host, \%args, ...);
  $self = $self->prepare(\@hosts, \%args, ...);
  $self = $self->prepare(\@hosts, ...);
  $self = $self->prepare('*' => ...);

=over 4

=item * $host

This can either be an array ref or a single host. The "host" can be whatever
L<Net::SNMP/session> can handle; generally a hostname or IP address.

=item * \%args

A hash ref of options which will be passed directly to L<Net::SNMP/session>.
This argument is optional. See also L</defaults>.

=item * dot-dot-dot

A list of key-value pairs of SNMP operations and bindlists which will be given
to L</prepare>. The operations are the same as the method names available in
L<Net::SNMP>, but without "_request" at end:

  get
  get_next
  set
  get_bulk
  inform
  walk
  bulk_walk
  ...

The special hostname "*" will apply the given operation to all previously
defined hosts.

=back

Examples:

  $self->prepare('192.168.0.1' => { version => 'v2c' }, get_next => [$oid, ...]);
  $self->prepare('192.168.0.1' => { version => 'v3' }, get => [$oid, ...]);
  $self->prepare(localhost => set => [ $oid => OCTET_STRING, $value, ... ]);
  $self->prepare('*' => get => [ $oid ... ]);

Note: To get the C<OCTET_STRING> constant and friends you need to do:

  use Net::SNMP ':asn1';

=cut

sub prepare {
  my $cb = ref $_[-1] eq 'CODE' ? pop : undef; # internal usage. might change
  my $self = shift;
  my $hosts = ref $_[0] eq 'ARRAY' ? shift : [shift];
  my $args = ref $_[0] eq 'HASH' ? shift : {};
  my %args = %$args;

  $hosts = [ sort keys %{ $self->_pool } ] if $hosts->[0] and $hosts->[0] eq '*';

  defined $args{$_} or $args{$_} = $self->defaults->{$_} for keys %{ $self->defaults };
  $args{version} = $self->_normalize_version($args{version} || '');
  delete $args{$_} for @{ $EXCLUDE{$args{version}} }, @EXCLUDE_METHOD_ARGS;
  delete $args{stash};

  HOST:
  for my $key (@$hosts) {
    my($host) = $key =~ /^([^|]+)/;
    local $args{hostname} = $host;
    my $key = $key eq $host ? $self->_calculate_pool_key(\%args) : $key;
    $self->_pool->{$key} ||= $self->_new_session(\%args) or next HOST;

    local @_ = @_;
    while(@_) {
      my $method = shift;
      my $oid = ref $_[0] eq 'ARRAY' ? shift : [shift];
      push @{ $self->_queue }, [ $key, $method, $oid, $args, $cb ];
    }
  }

  $self->{_requests} ||= 0;
  $self->_prepare_request or last for $self->{_requests} .. $self->concurrent - 1;
  $self->_setup if !$self->{_setup}++ and $self->ioloop->is_running;
  $self;
}

sub _calculate_pool_key {
  join '|', map { defined $_[1]->{$_} ? $_[1]->{$_} : '' } qw/ hostname version community username /;
}

sub _normalize_version {
  $_[1] =~ /1/ ? 'v1' : $_[1] =~ /3/ ? 'v3' : 'v2c';
}

sub _new_session {
  my($self, $args) = @_;
  my($session, $error) = Net::SNMP->session(%$args, nonblocking => 1);

  warn "[SNMP] New session $args->{hostname}: ", ($error || 'OK'), "\n" if DEBUG;
  $self->emit(error => "$args->{hostname}: $error") if $error;
  $session;
}

sub _prepare_request {
  my $self = shift;
  my $item = shift @{ $self->_queue } or return;
  my($key, $method, $list, $args, $cb) = @$item;
  my $session = $self->_pool->{$key};
  my $success;

  # dispatch to our mojo based dispatcher
  $Net::SNMP::DISPATCHER = $self->_dispatcher;
  warn "[SNMP] >>> $key $method(@$list)\n" if DEBUG;

  Scalar::Util::weaken($self);
  $method = $SNMP_METHOD{$method} || "$method\_request";
  $success = $session->$method(
    $method =~ /bulk/ ? (maxrepetitions => $args->{maxrepetitions} || MAXREPETITIONS) : (),
    ref $method ? (%$args) : (),
    varbindlist => $list,
    callback => sub {
      local @$args{qw/ method request /} = @$item[1, 2];
      if($_[0]->var_bind_list) {
        warn "[SNMP] <<< $key $method(@$list)\n" if DEBUG;
        $cb ? $self->$cb('', $_[0]) : $self->emit(response => $_[0], $args);
      }
      else {
        warn "[SNMP] <<< $key @{[$_[0]->error]}\n" if DEBUG;
        $cb ? $self->$cb($_[0]->error, undef) : $self->emit(error => $_[0]->error, $_[0], $args);
      }
      $self->_prepare_request;
      $self->_finish unless $self->_dispatcher->connections;
    },
  );

  return ++$self->{_requests} if $success;
  $self->emit(error => $session->error, $session);
  return $self->{_requests} || '0e0';
}

sub _finish {
  warn "[SNMP] Finish\n" if DEBUG;
  $_[0]->emit('finish');
  $_[0]->{_setup} = 0;
}

sub _setup {
  my $self = shift;
  my $timeout = $self->master_timeout or return;
  my $tid;

  warn "[SNMP] Timeout: $timeout\n" if DEBUG;
  Scalar::Util::weaken($self);

  $tid = $self->ioloop->timer($timeout => sub {
    warn "[SNMP] Timeout\n" if DEBUG;
    $self->ioloop->remove($tid);
    $self->emit('timeout');
    $self->{_setup} = 0;
  });
}

=head2 wait

This is useful if you want to block your code: C<wait()> starts the ioloop and
runs until L</timeout> or L</finish> is reached.

  my $snmp = Mojo::SNMP->new;
  $snmp->prepare(...)->wait; # blocks while retrieving data
  # ... your program continues after the SNMP operations have finished.

=cut

sub wait {
  my $self = shift;
  my $ioloop = $self->ioloop;
  my $stop;

  $stop = sub {
    $_[0]->unsubscribe(finish => $stop);
    $_[0]->unsubscribe(timeout => $stop);
    $ioloop->stop;
    undef $stop;
  };

  $self->_setup unless $self->{_setup}++;
  $self->once(finish => $stop);
  $self->once(timeout => $stop);
  $ioloop->start;
  $self;
}

=head2 add_custom_request_method

  $self->add_custom_request_method(name => sub {
    my($session, %args) = @_;
    # do custom stuff..
  });

This method can be used to add custom L<Net::SNMP> request methods. See the
source code for an example on how to do "walk".

NOTE: This method will also replace any method, meaning the code below will
call the custom callback instead of L<Net::SNMP/get_next_request>.

  $self->add_custom_request_method(get_next => $custom_callback);

=cut

sub add_custom_request_method {
  my($class, $name, $cb) = @_;
  $SNMP_METHOD{$name} = $cb;
  $class;
}

=head1 COPYRIGHT & LICENSE

This library is free software. You can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 AUTHOR

Jan Henning Thorsen - C<jhthorsen@cpan.org>

Joshua Keroes - C<joshua@cpan.org>

Espen Tallaksen

=cut

1;
