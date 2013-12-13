use ExtUtils::MakeMaker;
WriteMakefile(
  NAME => 'Mojo::SNMP',
  ABSTRACT_FROM => 'lib/Mojo/SNMP.pm',
  VERSION_FROM => 'lib/Mojo/SNMP.pm',
  AUTHOR => 'Jan Henning Thorsen <jhthorsen@cpan.org>',
  LICENSE => 'perl',
  PREREQ_PM => {
    'Mojolicious' => '4.30',
    'Net::SNMP' => 0,
  },
  BUILD_REQUIRES => {
    'Test::More' => '0.90',
  },
  META_MERGE => {
    resources => {
      license => 'http://dev.perl.org/licenses/',
      homepage => 'https://metacpan.org/release/Mojo-SNMP',
      bugtracker => 'https://github.com/jhthorsen/mojo-snmp/issues',
      repository => 'https://github.com/jhthorsen/mojo-snmp',
    },
  },
  test => {
    TESTS => 't/*.t',
  },
);
