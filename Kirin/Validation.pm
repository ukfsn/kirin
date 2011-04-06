package Kirin::Validation;

use strict;
use warnings;

use Regexp::Common;
use Data::Password::BasicCheck;
use Email::Valid;

my $valid_check = Email::Valid->new(-mxcheck => 1);
no strict 'vars';
our %validations = (
    'Printable' => sub {
        return $_[0] =~ /^[[:print:]]*$/ ? 1 : 0;
    },
    'Number' => sub {
        return $_[0] =~ /^$RE{num}{real}$/ ? 1 : 0;
    },
    'List' => sub {
        my %list = map { $_ => 1 } split(/,/, $_[1]);
        return defined $lists{$_[0]} ? 1 : 0;
    },
    'Country Code' => sub {
        return $_[0] =~ /^[a-zA-Z]{2}$/ ? 1 : 0;
    },
    'UK Postcode' => sub {
        return $_[0] =~  /^([A-PR-UWYZ0-9][A-HK-Y0-9][AEHMNPRTVXY0-9]?[ABEHMNPRVWXY0-9]? {1,2}[0-9][ABD-HJLN-UW-Z]{2}|GIR 0AA)$/ ? 1 : 0;
    },
    'Host Name' => sub {
        return $_[0] =~ /^(?! )$RE{net}{domain}$/ ? 1 : 0;
    },
    'Domain' => sub {
        return $_[0] =~ /^(?! )$RE{net}{domain}$/ ? 1 : 0;
    },
    'IP Address' => sub {
        return $_[0] =~ /^$RE{net}{IPv4}$/ ? 1 : 0;
    },
    'Email Address' => sub {
        return $valid_check->address($_[0]) ? 1 : 0;
    },
    'Telephone' => sub {
        return $_[0] =~ /^(\(?\+?[0-9]*\)?)?[0-9_\- \(\)]*$/ ? 1 : 0;
    },
    'Fax' => sub {
        return $_[0] =~ /^(\(?\+?[0-9]*\)?)?[0-9_\- \(\)]*$/ ? 1 : 0;
    },
    'UK Reg Type' => sub {
        return if ! defined $uk_reg_types{$_[0]};
        if ( $_[0] eq 'LTD' || $_[0] eq 'PLC' ) {
            if ( ! $_[2]->{registrant}{'co-no'} ) {
                $_[3]->message('Company Number is required');
                $_[4]->{error}{'co-no'}++;
                return;
            }
        }
        return 1;
    },
    'Regexp' => sub {
        my $re = $_[1];
        $re = qr/$re/ if not ref $re eq "Regexp";
        return $_[0] =~ $re ? 1 : 0;
    },
    'CODE' => sub {
        return $_[1]->($_[0]) ? 1 : 0;
    }
);

our %uk_reg_types = (
    LTD => 'UK Limited Company',
    PLC => 'UK Public Limited Company',
    PTNR => 'UK Partnership',
    STRA => 'UK Sole Trader',
    LLP => 'UK Limited Liability Partnership',
    IP => 'UK Industrial/Provident Registered Company',
    IND => 'UK Individual (representing self)',
    SCH => 'UK School',
    RCHAR => 'UK Registered Charity',
    GOV => 'UK Government Body',
    CRC => 'UK Corporation by Royal Charter',
    STAT => 'UK Statutory Body',
    OTHER => 'UK Entity that does not fit into any of the above (e.g. clubs, associations, many universities)',
    FIND => 'Non-UK Individual (representing self)',
    FCORP => 'Non-UK Corporation',
    FOTHER => 'Non-UK Entity that does not fit into any of the above (e.g. charities, schools, clubs, associations)'
);

sub names {
    return keys %validations;
}

sub domain_name {
    my ($self, $domain) = @_;
    return $validations{'Domain'}->($domain, undef);
}

sub email {
    my ($self, $email) = @_;
    return $validations{'Email Address'}->($email, undef);
}

sub valid_thing {
    my ($self, $type, $data) = @_;
    return $validation{$type}->($data);
}

sub validate_class {
    my ($self, $mm, $class, $prefix, $rv, $args) = @_;
    my $errors = undef;
    for my $a ($class->attributes) {
        my $field = $a->name;
        if ( defined $a->required && ! defined $rv->{$prefix}{$field} ) {
            $args->{error}{$prefix.'_'.$field}++;
            $mm->message($a->label." is required");
            $errors++;
            next;
        }
        next if ! defined $rv->{$prefix}{$field};
        if ( $validations{$a->validation_type} ) {
            if ( ! $validations{$a->validation_type}->($rv->{$prefix}{$field}, $a->validation, $rv, $mm, $args) ) {
                $args->{error}{$prefix.'_'.$field}++;
                $mm->message($a->label." is not valid");
                $errors++;
                next;;
            }
        }
    }
    return $errors ? 0 : 1;
}

1;

