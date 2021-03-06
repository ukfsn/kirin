use inc::Module::Install;
name        'Kirin';
abstract    'Web-based domain management system';
author      'Simon Cozens <simon@simon-cozens.org>';
include     'Module::AutoInstall';
license     'artistic';
perl_version '5.006';
all_from    "Kirin.pm";

requires    "Plack::Middleware::Session" => 0;
requires    "Plack::Request" => 0;
requires    "Plack" => 0;
requires    "Template" => 0;
requires    "Template::Plugin::Class" => 0;
requires    "Class::Data::Inheritable" => 0;
requires    "Time::Piece" => 0;
requires    "Authen::Passphrase" => 0;
requires    "Module::Pluggable" => 0;
requires    "Email::Send" => 0;
requires    "Class::DBI::SQLite" => 0;
requires    "Class::DBI::Loader" => 0;
requires    "Net::SSLeay" => 0;
requires    "File::Slurp" => 0;
requires    "Net::DNS" => 0;
requires    "Email::Valid" => 0;
requires    "UNIVERSAL::require" => 0;
requires  "Data::Password::BasicCheck" => 0;
recommends  "Business::PayPal" => 0;
recommends  "Regexp::Common::dns" => 0;
recommends  "Net::eNom" => 0.3;
recommends  "Net::KashFlow" => 0;
recommends  "Date::Holidays::EnglandWales" => 0;

auto_install;
WriteAll;
