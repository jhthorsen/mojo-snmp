package Mojo::SNMP;

=head1 NAME

Mojo::SNMP - Run SNMP requests with Mojo::IOLoop

=head1 SYNOPSIS

    use Mojo::SNMP;
    my $snmp = Mojo::SNMP->new;
    my @response;

    $snmp->on(response => sub {
        my($snmp, $session) = @_;
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

This module use L<Net::SNMP> and L<Mojo::IOLoop> to fetch data from hosts asynchronous.

=cut

use Mojo::Base 'Mojo::EventEmitter';
use Mojo::IOLoop;
use Mojo::SNMP::Dispatcher;
use Net::SNMP ();
use Scalar::Util;
use constant DEBUG => $ENV{MOJO_SNMP_DEBUG} ? 1 : 0;

my %EXCLUDE = (
    v1 => [qw/ username authkey authpassword authprotocol privkey privpassword privprotocol /],
    v2c => [qw/ username authkey authpassword authprotocol privkey privpassword privprotocol /],
    v3 => [qw/ community /],
);

$Net::SNMP::DISPATCHER = $Net::SNMP::DISPATCHER; # avoid warning

=head1 EVENTS

=head2 error

    $self->on(error => sub {
        my($self, $str, $session) = @_;
    });

Emitted on errors which may occur. C<$session> is set if the error is a result
of a L<Net::SNMP> method, such as L<get_request()|Net::SNMP/get_request>.

=head2 finish

    $self->on(finish => sub {
        my $self = shift;
    });

Emitted when all hosts has completed.

=head2 response

    $self->on(response => sub {
        my($self, $session) = @_;
    });

Called each time a host responds. The C<$session> is the current L<Net::SNMP>
object.

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

This attribute holds a hash ref with default arguments which should be passed
on to L<Net::SNMP/session>. This will be merged with the C<%args> given to
L</prepare>, but C<prepare()> is clever enough to filter out which arguments
that that is related to which SNMP version.

NOTE: SNMP version will default to "v2c" unless specified.

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
has _pool => sub { +{} };
has _queue => sub { +[] };
has _delay => 0.005;
has _dispatcher => sub { Mojo::SNMP::Dispatcher->new(ioloop => $_[0]->ioloop) };

=head1 METHODS

=head2 prepare

    $self = $self->prepare($host, \%args, ...);
    $self = $self->prepare(\@hosts, \%args, ...);
    $self = $self->prepare(\@hosts, ...);
    $self = $self->prepare('*' => ...);

=over 4

=item * $host

This can either be an array ref or a single host. The "host" can be whatever
L<Net::SNMP/session> can handle, which is (at least) a hostname or IP address.

=item * %args

A hash ref of options which will be passed directly to L<Net::SNMP/session>.
This argument is optional. See also L</defaults>.

=item * dot-dot-dot

The list of arguments given to L</prepare> should be a key value pair of SNMP
operations and bindlists to act on.

The special hostname "*" will apply the given request to all the previous
hosts defined.

Examples:

    $self->prepare('192.168.0.1' => { version => 'v2c' }, get_next => [$oid, ...]);
    $self->prepare('192.168.0.1' => { version => 'v3' }, get => [$oid, ...]);
    $self->prepare(localhost => set => [ $oid => OCTET_STRING, $value, ... ]);
    $self->prepare('*' => get => [ $oid ... ]);

Note: To get the C<OCTET_STRING> constant and friends you need to do:

    use Net::SNMP ':asn1';

=back

=cut

sub prepare {
    my $self = shift;
    my $hosts = ref $_[0] eq 'ARRAY' ? shift : [shift];
    my $args = ref $_[0] eq 'HASH' ? shift : {};

    $hosts = [ sort keys %{ $self->_pool } ] if $hosts->[0] and $hosts->[0] eq '*';

    defined $args->{$_} or $args->{$_} = $self->defaults->{$_} for keys %{ $self->defaults };
    $args->{version} = $self->_normalize_version($args->{version} || '');
    delete $args->{$_} for @{ $EXCLUDE{$args->{version}} };

    HOST:
    for my $key (@$hosts) {
        my($host) = $key =~ /^([^|]+)/;
        local $args->{hostname} = $host;
        my $key = $key eq $host ? $self->_calculate_pool_key($args) : $key;
        $self->_pool->{$key} ||= $self->_new_session($args) or next HOST;

        local @_ = @_;
        while(@_) {
            my $method = shift;
            my $oid = ref $_[0] eq 'ARRAY' ? shift : [shift];
            push @{ $self->_queue }, [ $key, "$method\_request", $oid ]
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

    return $session if $session and not $error;
    warn "[SNMP] New session $args->{hostname}: $error\n" if DEBUG;
    $self->emit(error => "$args->{hostname}: $error");
    return;
}

sub _prepare_request {
    my $self = shift;
    my $item = shift @{ $self->_queue } or return 0;
    my($key, $method, $list) = @$item;
    my $session = $self->_pool->{$key};
    my $dispatcher = $self->_dispatcher;
    my $success;

    # dispatch to custom dispatcher
    local $Net::SNMP::DISPATCHER = $dispatcher;

    warn "[SNMP] >>> $key $method(@$list)\n" if DEBUG;
    Scalar::Util::weaken($self);
    $success = $session->$method(
        varbindlist => $list,
        callback => sub {
            my $session = shift;
            if($session->var_bind_list) {
                warn "[SNMP] <<< $key $method(@$list)\n" if DEBUG;
                $self->emit_safe(response => $session);
            }
            else {
                warn "[SNMP] <<< $key @{[$session->error]}\n" if DEBUG;
                $self->emit_safe(error => $session->error, $session);
            }
            $self->_prepare_request;
            $self->emit('finish') unless $dispatcher->connections;
        },
    );

    return ++$self->{_requests} if $success;
    $self->emit_safe(error => $session->error, $session);
    return $self->{_requests} || '0e0';
}

sub _setup {
    my $self = shift;
    my $timeout = $self->master_timeout or return;
    my $ioloop = $self->ioloop;
    my $tid;

    Scalar::Util::weaken($ioloop);
    Scalar::Util::weaken($self);

    $timeout += time;
    $tid = $ioloop->timer($timeout => sub {
        warn "[SNMP] Timeout\n" if DEBUG;
        $ioloop->remove($tid);
        $self->emit_safe('timeout');
        $self->{_setup} = 0;
    });
}

=head2 wait

This is useful if you want to block your code: C<wait()> starts the ioloop and
runs until L</timeout> or L</finish> is reached.

    $snmp = Mojo::SNMP->new;
    $snmp->prepare(...)->wait; # blocks while retrieving data
    # ... your program continues after completion

=cut

sub wait {
    my $self = shift;
    my $ioloop = $self->ioloop;
    my $stop;

    $stop = sub {
        $_[0]->unsubscribe(finish => $stop);
        $_[0]->unsubscribe(timeout => $stop);
        $ioloop->stop;
    };

    $self->_setup unless $self->{_setup}++;
    $self->once(finish => $stop);
    $self->once(timeout => $stop);
    $ioloop->start;
    $self;
}

=head1 COPYRIGHT & LICENSE

This library is free software. You can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 AUTHOR

Jan Henning Thorsen - jhthorsen@cpan.org

=cut

1;
