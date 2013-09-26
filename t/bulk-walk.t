use warnings;
use strict;
use Test::More;
use Mojo::SNMP;

my $snmp = Mojo::SNMP->new;
my %args;
{
  no warnings 'redefine';
  *Net::SNMP::get_bulk_request = sub { shift; %args = @_ };
}

{
  $snmp->prepare('1.2.3.4', { version => '2c', maxrepetitions => 2 }, bulk_walk => [qw/ 1.3.6.1.2.1.1.4.0 /]);
  is_deeply(
    [ sort keys %args ],
    [ qw( callback maxrepetitions varbindlist ) ],
    'get_bulk was called with callback, maxrepetitions and varbindlist',
  );
  is $args{maxrepetitions}, 2, 'maxrepetitions=2';
}

done_testing;
