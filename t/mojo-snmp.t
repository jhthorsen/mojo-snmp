use Test::More;
use Mojo::SNMP;

my $snmp = Mojo::SNMP->new;
my $finish = 0;

$snmp->on(response => sub {
    my($host, $snmp, $varbindlist) = @_;
    diag "response: $snmp";
});

$snmp->on(error => sub {
    my($host, $error, $snmp) = @_;
    diag "error: $error";
});

$snmp->on(finish => sub {
    diag 'finish!';
    $finish++;
});

$snmp->add('127.0.0.1', get => ['1.2.3']);
$snmp->wait;

is $finish, 1, 'finish event was emitted';

done_testing;
