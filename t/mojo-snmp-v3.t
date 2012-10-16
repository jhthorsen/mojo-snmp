use strict;
use warnings;
use Test::More;
use Mojo::SNMP;

my $snmp = Mojo::SNMP->new;
my(@response, @error, $timeout, $finish);

plan skip_all => 'Crypt::DES is required' unless eval 'require Crypt::DES; 1';
plan skip_all => 'Digest::HMAC is required' unless eval 'require Digest::HMAC; 1';
plan tests => 16;

$snmp->concurrent(0); # required to set up the queue
$snmp->defaults({ timeout => 1, community => 'public', username => 'foo' });
$snmp->on(response => sub { push @response, $_[1]->var_bind_list });
$snmp->on(error => sub { note "error: $_[1]"; push @error, $_[1] });
$snmp->on(finish => sub { $finish++ });
$snmp->on(timeout => sub { $timeout++ });

isa_ok $snmp->ioloop, 'Mojo::IOLoop';
is $snmp->master_timeout, 0, 'master_timeout is disabled by default';
is $snmp->_delay, 0.005, '_delay may be changed future releases';

$snmp->prepare('1.2.3.5', { version => 3 }, get => [qw/ 1.3.6.1.2.1.1.5.0 /]);
ok $snmp->_pool->{'1.2.3.5|v3||foo'}, '1.2.3.5 v3 foo';

$snmp->prepare('*', get_next => '1.2.3');

is $snmp->{_setup}, 2, 'prepare was called twice (stupid test)';
is $snmp->{_requests}, 0, 'and zero requests were prepared';

is_deeply($snmp->_queue, [
    [ '1.2.3.5|v3||foo', 'get_request', ['1.3.6.1.2.1.1.5.0'] ],

    # *
    [ '1.2.3.5|v3||foo', 'get_next_request', ['1.2.3'] ],
],
'queue is set up');

my $net_snmp = Net::SNMP->new(nonblocking => 1);
my($guard, @request);
no warnings 'redefine';
*Net::SNMP::get_next_request = sub { shift; push @request, @_ };
*Net::SNMP::get_request = sub { shift; push @request, @_ };

$snmp->concurrent(2);
$snmp->prepare('*');
is $snmp->{_requests}, 2, 'prepared two requests';
is int(@{ $snmp->_queue }), 0, 'zero requests left in the queue';
is_deeply $request[1], ['1.3.6.1.2.1.1.5.0'], 'varbindlist was passed on to get_request';
is ref $request[3], 'CODE', 'callback was passed on to get_request';
is_deeply $request[5], ['1.2.3'], 'varbindlist was passed on to get_next_request';
is ref $request[7], 'CODE', 'callback was passed on to get_next_request';

is int(@{ $snmp->_queue }), 0, 'queue is empty';

$guard = 10000;
$snmp->ioloop->one_tick while $guard--;
is $finish, 1, 'on(finish) was triggered';

$snmp->master_timeout(-1);
$snmp->_setup;
$guard = 10000;
$snmp->ioloop->one_tick while $guard--;
is $timeout, 1, 'on(timeout) was triggered';

done_testing;
