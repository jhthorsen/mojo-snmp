use strict;
use warnings;
use Test::More;
use Mojo::SNMP;

plan skip_all => 'LIVE_TEST=0' unless $ENV{LIVE_TEST};

my $snmp = Mojo::SNMP->new;
my(@response, @error, $finish);

$snmp->on(response => sub { push @response, $_[1]->var_bind_list });
$snmp->on(error => sub { push @error, $_[1] });
$snmp->on(finish => sub { $finish++ });

$snmp->defaults({ community => 'public', version => 2 });

@response = ();
$snmp->prepare('127.0.0.1', { timeout => 1 }, get => [qw/ 1.2.42.42 /])->wait;
is $response[0]{'1.2.42.42'}, 'noSuchObject', '1.2.42.42 does not exist';

@response = ();
$snmp->prepare('127.0.0.1', { timeout => 1 },
    get => [qw/ 1.3.6.1.2.1.1.3.0 1.3.6.1.2.1.1.4.0 /],
    get => [qw/ 1.3.6.1.2.1.1.4.0 /],
    get_next => [qw/ 1.3.6.1.2.1 /],
)->wait;

is $finish, 2, 'finish event was emitted';
ok defined $response[0]{'1.3.6.1.2.1.1.3.0'}, 'got uptime';
ok defined $response[0]{'1.3.6.1.2.1.1.4.0'}, 'got contact name';
ok defined $response[1]{'1.3.6.1.2.1.1.4.0'}, 'got contact name';
ok defined $response[2]{'1.3.6.1.2.1.1.1.0'}, 'get_next system name';

done_testing;
