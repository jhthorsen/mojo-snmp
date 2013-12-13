use strict;
use warnings;
use Test::More;
use Mojo::SNMP;

plan skip_all => 'Crypt::DES is required' unless eval 'require Crypt::DES; 1';

my $snmp = Mojo::SNMP->new;
my(@response, @extra, $timeout, $finish);

$snmp->concurrent(0); # required to set up the queue
$snmp->defaults({ timeout => 1, community => 'public', username => 'foo' });
$snmp->on(response => sub { push @extra, 'aiai' });
$snmp->on(error => sub { note "error: $_[1]"; push @extra, $_[1] });
$snmp->on(finish => sub { $finish++ });
$snmp->on(timeout => sub { $timeout++ });

$snmp->get('1.2.3.4', { version => '2c' }, [qw/ 1.3.6.1.2.1.1.4.0 /], \&got_res);
$snmp->get_next('1.2.3.5' => [qw/ 1.3.6.1.2.1.1.6.0 /], \&got_res);

is_deeply(
  $snmp->_queue,
  [
    [ '1.2.3.4|v2c|public|', 'get', ['1.3.6.1.2.1.1.4.0'], { version => '2c' }, \&got_res ],
    [ '1.2.3.5|v2c|public|', 'get_next', ['1.3.6.1.2.1.1.6.0'], {}, \&got_res ],
  ],
  'queue is set up'
);

my $net_snmp = Net::SNMP->new(nonblocking => 1);
my($guard, @request);
no warnings 'redefine';
*Net::SNMP::get_next_request = sub { shift; push @request, @_ };
*Net::SNMP::get_request = sub { shift; push @request, @_ };
$net_snmp->{_error} = 'yikes!';

$snmp->concurrent(2);
$snmp->prepare('*');
is $snmp->{_requests}, 2, 'prepared two requests';
is_deeply $request[1], ['1.3.6.1.2.1.1.4.0'], 'varbindlist was passed on to get_request';
is ref $request[3], 'CODE', 'callback was passed on to get_request';
is_deeply $request[5], ['1.3.6.1.2.1.1.6.0'], 'varbindlist was passed on to get_next_request';
is ref $request[7], 'CODE', 'callback was passed on to get_next_request';

done_testing;

sub got_res { shift; push @response, @_ }
