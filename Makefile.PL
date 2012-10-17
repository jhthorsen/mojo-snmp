use inc::Module::Install;

name q(Mojo-SNMP);
all_from q(lib/Mojo/SNMP.pm);

recommends q(Test::Compile) => 0;
recommends q(Crypt::DES) => 0;
recommends q(Digest::HMAC) => 0; # for SNMPv3
requires q(Errno) => 1.13;
requires q(Mojolicious) => 3.38;
requires q(Net::SNMP) => 0; # tested with v6.0.1
requires q(Scalar::Util) => 1.20;

bugtracker q(http://rt.cpan.org/NoAuth/Bugs.html?Dist=Mojo-SNMP);
homepage q(https://metacpan.org/release/Mojo-SNMP);
repository q(git://github.com/jhthorsen/mojo-snmp.git);

auto_install;
WriteAll;
