package Mojo::SNMP;

=head1 NAME

Mojo::SNMP - Run SNMP requests with Mojo::IOLoop

=head1 SYNOPSIS

    use Mojo::SNMP;
    my $snmp = Mojo::SNMP->new;

    $snmp->on(response => sub {
        my($host, $error, $res) = @_;
    });

    $snmp->add('127.0.0.1', get => ['1.2.3']);
    $snmp->start;

=head1 DESCRIPTION

This module use L<Net::SNMP> to fetch data from hosts asynchronous.

=cut

use Mojo::Base 'Mojo::EventEmitter';
use constant DEBUG => $ENV{MOJO_SNMP_DEBUG} ? 1 : 1;
use Mojo::IOLoop;
use Scalar::Util;
use Net::SNMP ();

my %NET_SNMP_ARGS = (
    version => '2c',
    community => 'public',
    timeout => 1,
    retries => 0,
);

=head1 EVENTS

=head2 response

    $self->on(response => sub {
        my($self, $host, $res) = @_;
    });

Called each time a host responds or timeout. C<$res> will be a hash ref on
success and a plain string on error.

=head2 finish

    $self->on(finish => sub {
        my $self = shift;
    });

Emitted when all hosts has timed out or completed.

=head2 timeout

    $self->on(timeout => sub {
        my $self = shift;
    })

This method is called if the L</timeout> attribute is set and time has is
passed.

=head1 ATTRIBUTES

=head2 concurrent

How many hosts to fetch data from at once. Default is 20.

=head2 timeout

How long to run in total before timeout. Note: This is NOT pr host but for
complete run. Default is 0, meaning run for as long as you have to.

=head2 ioloop

Holds an instance of L<Mojo::IOLoop>.

=cut

has concurrent => 20;
has timeout => 0;
has ioloop => sub { Mojo::IOLoop->singleton };
has _pool => sub { +{} };
has _queue => sub { +[] };
has _tid => 0;

=head1 METHODS

=head2 add

    $self = $self->add($host, \%args, ...);
    $self = $self->add(\@hosts, \%args, ...);
    $self = $self->add(all => ...);

=over 4

=item * host

=item * args

=item * get

=item * getnext

=item * walk

=item * set

=back

=cut

sub add {
    my $self = shift;
    my $hosts = ref $_[0] eq 'ARRAY' ? shift : [shift];
    my $args = ref $_[0] eq 'HASH' ? shift : { %NET_SNMP_ARGS };

    $hosts = [ keys %{ $self->_pool } ] if $hosts->[0] eq 'all';

    for my $host (@$hosts) {
        $self->_pool->{$host} ||= $self->_new_session($host, $args);

        local @_ = @_;
        while(@_) {
            my $method = shift;
            my $oid = ref $_[0] eq 'ARRAY' ? shift : [shift];
            push @{ $self->_queue }, [ $host, $method, $oid ]
        }
    }

    $self;
}

sub _new_session {
    my $args = $_[2]->{args} || { %NET_SNMP_ARGS };
    my($session, $error) = Net::SNMP->session(hostname => $_[1], %$args);
    die $error unless $session;
    return $session;
}

sub _id {
    my $host = $_[1]->{host} or return;
    my $args = $_[1]->{args} || \%NET_SNMP_ARGS;

    # NOTE: The key list might change in future versions
    join('|',
        $host,
        map { defined $args->{$_} ? $args->{$_} : '_' } qw/
            port
            version
            community
            username
        /
    );
}

=head2 start

    $self = $self->start;

Will prepare the ioloop to send and receive data to the hosts prepared with
L</add>. This ioloop will abort the job if L</timeout> is set and time the
time has past.

=cut

sub start {
    my $self = shift;
    my $ioloop = $self->ioloop;
    my($snmp) = values %{ $self->_pool };
    my $timeout = $self->timeout ? time + $self->timeout : 0;
    my $tid;

    warn "[SNMP] Gather information from " .int(keys %{ $self->_pool }) ." hosts\n" if DEBUG;

    unless($snmp and @{ $self->_queue }) {
        $self->emit_safe('finish');
        return $self;
    }

    $tid = $ioloop->recurring(0.01, sub {
        if($timeout and $timeout < time) {
            $ioloop->remove($tid);
            $self->emit_safe('timeout');
        }
        elsif(!$snmp->snmp_dispatch_once) {
            $ioloop->remove($tid);
            $self->emit_safe('finish');
        }
    });

    $self->{_current} ||= 0;
    $self->_start_request for $self->{_current} .. $self->concurrent;
    $self;
}

sub _start_request {
    my $self = shift;
    my $item = shift @{ $self->_queue } or return;
    my($host, $action, $varbindlist) = @$item;
    my $session = $self->_pool->{$host};

    warn "[SNMP] $action(@$varbindlist) from $host\n" if DEBUG;
    Scalar::Util::weaken($self);
    $session->${ \ "$action\_request" }(
        varbindlist => $varbindlist,
        callback => sub {
            $self->emit(response => $host, @_);
            $self->_start_requests;
            $self->emit('finish') unless --$self->{_current};
        },
    );

    $self->{_current}++;
}

=head2 wait

This is an alternative to L</start> if you want to block in your code:
C<wait()> starts the ioloop and runs until L</timeout> or L</finish> is
reached.

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

    $self->once(finish => $stop);
    $self->once(timeout => $stop);
    $self->start;
    $ioloop->start;
    $self;
}

=head1 AUTHOR

Jan Henning Thorsen - jhthorsen@cpan.org

=cut

1;
