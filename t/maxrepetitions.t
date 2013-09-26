use warnings;
use strict;
use Test::More;
use Mojo::SNMP;

my $snmp = Mojo::SNMP->new;
my %args;

{
  $snmp->concurrent(0);
  $snmp->prepare('1.2.3.4', { version => '2c', maxrepetitions => 10 }, get_bulk => [qw/ 1.3.6.1.2.1.1.4.0 /]);

  is_deeply(
    $snmp->_queue,
    [
      [ '1.2.3.4|v2c||', 'get_bulk', ['1.3.6.1.2.1.1.4.0'], { version => '2c', maxrepetitions => 10 } ],
    ],
    'queued get_bulk with maxrepetitions',
  );
}

{
  no warnings 'redefine';
  *Net::SNMP::get_bulk_request = sub { shift; %args = @_ };
  *Net::SNMP::get_next_request = sub { shift; %args = @_ };
}

{
  $snmp->_prepare_request;
  is_deeply(
    [ sort keys %args ],
    [ qw( callback maxrepetitions varbindlist ) ],
    'get_bulk was called with callback, maxrepetitions and varbindlist',
  );
}

{
  $snmp->prepare('1.2.3.4', { version => '2c', maxrepetitions => 10 }, get_next => [qw/ 1.3.6.1.2.1.1.4.0 /]);
  $snmp->_prepare_request;
  is_deeply(
    [ sort keys %args ],
    [ qw( callback varbindlist ) ],
    'get_next was not called with maxrepetitions',
  );
}

done_testing;
