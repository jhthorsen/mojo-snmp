use Mojo::Base -strict;
use Test::More;
use Mojo::SNMP;

plan skip_all => 'LIVE_TEST=0' unless $ENV{LIVE_TEST};

my $snmp  = Mojo::SNMP->new;
my $limit = 30;
my $get_next;
my @res;

$get_next = sub {
  my ($snmp, $err, $res) = @_;
  push @res, $err || join ',', values %{$res->var_bind_list} if @_ == 3;
  $snmp->get_next('127.0.0.1', ['1.3.6.1.2.1'], $get_next);
  Mojo::IOLoop->stop if @res == $limit;
};

$snmp->$get_next;
Mojo::IOLoop->timer(2 => sub { push @res, 'TIMEOUT!'; Mojo::IOLoop->stop; });
Mojo::IOLoop->start;

is int(@res), $limit, 'not stopped by concurrent limit';
diag join "\n", @res;

done_testing;
