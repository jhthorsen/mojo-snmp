use inc::Module::Install;

name q(Mojo-SNMP);
all_from q(lib/Mojo/SNMP.pm);

recommends q(Test::Compile) => 0;
requires q(Mojolicious) => 3.38;
requires q(SNMP) => 5.04;

bugtracker q(http://rt.cpan.org/NoAuth/Bugs.html?Dist=Mojo-SNMP);
homepage q(https://metacpan.org/release/Mojo-SNMP);
repository q(git://github.com/jhthorsen/mojo-snmp.git);

auto_install;
WriteAll;
