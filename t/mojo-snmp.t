use Test::More;
use Mojo::SNMP;

my $snmp = Mojo::SNMP->new;
my $finish = 0;

$snmp->on(response => sub {
    my($host, $error, $res) = @_;
    diag 'response!';
});

$snmp->on(finish => sub {
    diag 'finish!';
    $finish++;
});

$snmp->add('127.0.0.1', get => ['1.2.3']);
$snmp->run;

is $finish, 1, 'finish event was emitted';

done_testing;