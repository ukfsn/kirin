package Kirin::Validation;

use strict;
use warnings;

use Regexp::Common;
use Data::Password::BasicCheck;
use Email::Valid;

my $valid_check = Email::Valid->new(-mxcheck => 1);
no strict 'vars';
my %validations = (
    'Printable' => sub {
        return $_[0] =~ /^[[:print:]]*$/ ? 1 : 0;
    },
    'Number' => sub {
        return $_[0] =~ /^$RE{num}{real}$/ ? 1 : 0;
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
    'Regexp' => sub {
        my $re = $_[1];
        $re = qr/$re/ if not ref $re eq "Regexp";
        return $_[0] =~ $re ? 1 : 0;
    },
    'CODE' => sub {
        return $_[1]->($_[0]) ? 1 : 0;
    }
);

sub names {
    return keys %validations;
}

sub validate_class {
    my ($self, $mm, $class) = @_;
    my $params = $mm->{req}->parameters();
    my $errors;
    for my $a ($class->attributes) {
        if ( defined $a->required && ! $params->{$a->name} ) {
            $mm->message($a->name." is required");
            $errors++;
            next;
        }
        next if ! defined $params->{$a->name};
        if ( defined $a->min_length && length $params->{$a->name} < $a->min_length ) {
            $mm->message($a->name." must be at least ".$a->min_length." characters long");
            $errors++;
            next;
        }
        if ( defined $a->max_length && length $params->{$a->name} > $a->max_length ) {
            $mm->message($a->name." cannot be longer than ".$a->max_length);
            $errors++;
            next;
        }
        if ( $validation{$a->validation_type} ) {
            if ( ! $validations{$a->validation_type}->($params->{$a->name}, $a->validation) ) {
                $mm->message($a->name." is not a valid ".$a->validation);
                $errors++;
                next;;
            }
        }
    }
    return $errors ? 0 : 1;
}

1;

