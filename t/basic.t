use strict;
use warnings;
use Test::More;
use Mojo::SNMP;
use constant TEST_MEMORY => $ENV{TEST_MEMORY} && eval 'use Test::Memory::Cycle; 1';

diag 'Test::Memory::Cycle is not available' unless TEST_MEMORY;
plan skip_all => 'Crypt::DES is required' unless eval 'require Crypt::DES; 1';

my $snmp = Mojo::SNMP->new;
$snmp->concurrent(0); # required to set up the queue
$snmp->defaults({ timeout => 1, community => 'public', username => 'foo' });

memory_cycle_ok($snmp) if TEST_MEMORY;
isa_ok $snmp->ioloop, 'Mojo::IOLoop';
isa_ok $snmp->_dispatcher, 'Mojo::SNMP::Dispatcher';
is $snmp->master_timeout, 0, 'master_timeout is disabled by default';
is $snmp->_dispatcher->ioloop, $snmp->ioloop, 'same ioloop';

$snmp->prepare('1.2.3.4', { version => '2c' }, get => [qw/ 1.3.6.1.2.1.1.4.0 /]);
ok $snmp->_pool->{'1.2.3.4|v2c|public|'}, '1.2.3.4 v2c public';

$snmp->prepare('1.2.3.5', get_next => [qw/ 1.3.6.1.2.1.1.6.0 /]);
ok $snmp->_pool->{'1.2.3.5|v2c|public|'}, '1.2.3.5 v2c public';

$snmp->prepare('1.2.3.5', { version => 3 }, get => [qw/ 1.3.6.1.2.1.1.5.0 /]);
ok $snmp->_pool->{'1.2.3.5|v3||foo'}, '1.2.3.5 v3 foo';
memory_cycle_ok($snmp) if TEST_MEMORY;

$snmp->prepare('127.0.0.1', { version => '2', community => 'foo' },
    get => [qw/ 1.3.6.1.2.1.1.3.0 1.3.6.1.2.1.1.4.0 /],
    get_next => [qw/ 1.3.6.1.2.1 /],
);
ok $snmp->_pool->{'127.0.0.1|v2c|foo|'}, '127.0.0.1 v2c foo';

$snmp->prepare('127.0.0.1', { retries => '2', community => 'bar', version => 'snmpv1' });
ok $snmp->_pool->{'127.0.0.1|v1|bar|'}, '127.0.0.1 v1 bar';

$snmp->prepare('*', get_next => '1.2.3');

is $snmp->{_setup}, 6, 'prepare was called six times (stupid test)';
is $snmp->{_requests}, 0, 'and zero requests was prepared';

is_deeply($snmp->_queue, [
    [ '1.2.3.4|v2c|public|', 'get_request', ['1.3.6.1.2.1.1.4.0'] ],
    [ '1.2.3.5|v2c|public|', 'get_next_request', ['1.3.6.1.2.1.1.6.0'] ],
    [ '1.2.3.5|v3||foo', 'get_request', ['1.3.6.1.2.1.1.5.0'] ],
    [ '127.0.0.1|v2c|foo|', 'get_request', [qw/ 1.3.6.1.2.1.1.3.0 1.3.6.1.2.1.1.4.0 /] ],
    [ '127.0.0.1|v2c|foo|', 'get_next_request', [qw/ 1.3.6.1.2.1 /] ],

    # *
    [ '1.2.3.4|v2c|public|', 'get_next_request', ['1.2.3'] ],
    [ '1.2.3.5|v2c|public|', 'get_next_request', ['1.2.3'] ],
    [ '1.2.3.5|v3||foo', 'get_next_request', ['1.2.3'] ],
    [ '127.0.0.1|v1|bar|', 'get_next_request', ['1.2.3'] ],
    [ '127.0.0.1|v2c|foo|', 'get_next_request', ['1.2.3'] ],
],
'queue is set up');

memory_cycle_ok($snmp) if TEST_MEMORY;
done_testing;
