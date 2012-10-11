package Mojo::SNMP;

=head1 NAME

Mojo::SNMP - Run SNMP requests with Mojo::IOLoop

=head1 SYNOPSIS

    use Mojo::SNMP;
    my $snmp = Mojo::SNMP->new;

    $snmp->on(response => sub {
        my($host, $session) = @_;
    });

    $snmp->prepare('127.0.0.1', get => ['1.2.3']);
    $snmp->wait;

=head1 DESCRIPTION

This module use L<Net::SNMP> to fetch data from hosts asynchronous.

=cut

use Mojo::Base 'Mojo::EventEmitter';
use constant DEBUG => $ENV{MOJO_SNMP_DEBUG} ? 1 : 1;
use Mojo::IOLoop;
use Scalar::Util;
use Net::SNMP ();

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

How many hosts to fetch data from at once. Default is 20.

=head2 master_timeout

How long to run in total before timeout. Note: This is NOT per host but for
the complete run. Default is 0, meaning run for as long as you have to.

=head2 ioloop

Holds an instance of L<Mojo::IOLoop>.

=cut

has concurrent => 20;
has master_timeout => 0;
has ioloop => sub { Mojo::IOLoop->singleton };
has _pool => sub { +{} };
has _queue => sub { +[] };

# these attributes are experimental and therefore not exposed. Let me know if
# you use them...
has _delay => 0.005;
has _default_session_args => sub {
    +{
        version => '2c',
        community => 'public',
        timeout => 10,
        retries => 0,
    };
};

=head1 METHODS

=head2 prepare

    $self = $self->prepare($host, \%args, ...);
    $self = $self->prepare(\@hosts, \%args, ...);
    $self = $self->prepare(all => \%args, ...);

=over 4

=item * $host

This can either be an array ref or a single host. The "host" can be whatever
L<Net::SNMP/session> can handle, which is (at least) a hostname or IP address.
The special hostname "*" will apply the given arguments to all the previous
hosts defined.

=item * %args

A hash ref of options which will be passed directly to L<Net::SNMP/session>.
This argument is optional.

=item * dot-dot-dot

The list of arguments given to L</prepare> should be a key value pair of SNMP
operations and bindlists to act on.

Examples:

    $self->prepare('192.168.0.1' => walk => [$oid, ...]);
    $self->prepare(localhost => set => { $oid => $value, ... });
    $self->prepare('*' => { community => 's3cret' }, get => [$oid, ...]);

=back

=cut

sub prepare {
    my $self = shift;
    my $hosts = ref $_[0] eq 'ARRAY' ? shift : [shift];
    my $args = ref $_[0] eq 'HASH' ? shift : $self->_default_session_args;

    $hosts = [ keys %{ $self->_pool } ] if $hosts->[0] eq '*';

    HOST:
    for my $host (@$hosts) {
        $self->_pool->{$host} ||= $self->_new_session($host, $args) or next HOST;

        local @_ = @_;
        while(@_) {
            my $method = shift;
            my $oid = ref $_[0] eq 'ARRAY' ? shift : [shift];
            push @{ $self->_queue }, [ $host, "$method\_request", $oid ]
        }
    }

    $self->{_requests} ||= 0;
    $self->_setup unless $self->{_setup}++;
    $self->_prepare_request or last for $self->{_requests} .. $self->concurrent;
    $self;
}

sub _new_session {
    my($self, $host, $args) = @_;
    my($session, $error) = Net::SNMP->session(%$args, hostname => $host, nonblocking => 1);
    $self->emit(error => "$host: $error") if (! $session || $error);
    $session;
}

sub _prepare_request {
    my $self = shift;
    my $item = shift @{ $self->_queue } or return 0;
    my($host, $method, $varbindlist) = @$item;
    my $res;

    warn "[SNMP] $method(@$varbindlist) from $host\n" if DEBUG;
    Scalar::Util::weaken($self);
    $res = $self->_pool->{$host}->$method(
        varbindlist => $varbindlist,
        callback => sub {
            my $session = shift;
            if($session->var_bind_list) {
                $self->emit_safe(response => $session);
            }
            else {
                $self->emit_safe(error => $session->error, $session);
            }
            $self->_prepare_request;
        },
    );

    return ++$self->{_requests} if $res;
    $self->emit_safe(error => $self->_pool->{$host}->error, $self->_pool->{$host});
    return $self->{_requests} || '0e0';
}

sub _setup {
    my $self = shift;
    my $ioloop = $self->ioloop;
    my $tid;

    Scalar::Util::weaken($ioloop);
    Scalar::Util::weaken($self);

    if(my $timeout = $self->master_timeout) {
        $timeout += time;
        $tid = $ioloop->recurring($self->_delay, sub {
            if($timeout < time) {
                $ioloop->remove($tid);
                $self->emit_safe('timeout');
            }
            elsif(not Net::SNMP::snmp_dispatch_once) {
                $ioloop->remove($tid);
                $self->emit_safe('finish');
            }
        });
    }
    else {
        $tid = $ioloop->recurring($self->_delay, sub {
            unless(Net::SNMP::snmp_dispatch_once) {
                $ioloop->remove($tid);
                $self->emit_safe('finish');
            }
        });
    }
}

=head2 wait

This is useful if you want to block your code: C<wait()> starts the ioloop and
runs until L</timeout> or L</finish> is reached.

    $snmp = Mojo::SNMP->new;
    $snmp->prepare(...);
    $snmp->wait; # blocks while retrieving data
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

    $self->once(finish => $stop);
    $self->once(timeout => $stop);
    $ioloop->start;
    $self;
}

=head1 AUTHOR

Jan Henning Thorsen - jhthorsen@cpan.org

=cut

1;
