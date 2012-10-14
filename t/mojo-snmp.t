use strict;
use warnings;
use Test::More;
use Mojo::SNMP;

my $snmp = Mojo::SNMP->new;
my(@response, @error, $finish);

$snmp->on(response => sub {
    my($self, $session) = @_;
    push @response, $session->var_bind_list;
});

$snmp->on(error => sub {
    my($host, $error, $session) = @_;
    push @error, $error;
});

$snmp->on(finish => sub {
    $finish++;
});

$snmp->prepare('127.0.0.1', { timeout => 1 }, get => ['1.2.42.42'])->wait;
plan skip_all => $error[0] unless $error[0] =~ /noSuchName/;

$snmp->prepare('127.0.0.1',
    { timeout => 1 },
    get => [qw/ 1.3.6.1.2.1.1.3.0 1.3.6.1.2.1.1.4.0 /],
    get => [qw/ 1.3.6.1.2.1.1.4.0 /],
    get_next => [qw/ 1.3.6.1.2.1 /],
);
$snmp->wait;

is $finish, 2, 'finish event was emitted';
ok defined $response[0]{'1.3.6.1.2.1.1.3.0'}, 'got uptime';
ok defined $response[0]{'1.3.6.1.2.1.1.4.0'}, 'got contact name';
ok defined $response[1]{'1.3.6.1.2.1.1.4.0'}, 'got contact name';
ok defined $response[2]{'1.3.6.1.2.1.1.1.0'}, 'get_next system name';

done_testing;
