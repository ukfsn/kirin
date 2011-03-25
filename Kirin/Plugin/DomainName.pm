package Kirin::Plugin::DomainName;
use Regexp::Common qw/net/;
use Net::DomainRegistration::Simple;
use List::Util qw/sum/;
use strict;
use base 'Kirin::Plugin';
use Time::Seconds;
sub name      { "domain_name" }
sub default_action { "list" }
sub user_name {"Domain Names"}

use JSON;

my $json = JSON->new->allow_blessed->allow_nonref;

my @fieldmap = (
    # Label, field for N::DR::S, field from customer profile
    ["First Name", "firstname", "forename"],
    ["Last Name", "lastname", "surname"],
    ["Company", "company", "org"],
    ["Trading Name", "trad-name", "trad-name"],
    ["Address", "address", "address"],
    ["City", "city", "town"],
    ["State", "state", "county"],
    ["Postcode", "postcode", "postcode"],
    ["Country", "country", "country"],
    ["Email", "email", "email"],
    ["Phone", "phone", "phone"],
);

sub list {
    my ($self, $mm) = @_;
    my %args = ();
    $args{names} = [Kirin::DB::DomainName->search(customer => $mm->{customer})];
    if ( $mm->{user}->is_root ) {
        $args{admin}++;
    }
    $mm->respond("plugins/domain_name/list", %args);
}

sub view {
    my ($self, $mm, $id) = @_;
    my %rv = $self->_get_domain($mm, $id);
    return $rv{response} if exists $rv{response};

    my ($domain, $handle) = ($rv{object}, $rv{reghandle});
    %rv = ();
    $rv{db} = $domain;
    eval {$rv{lr} = $handle->domain_info($domain->domain)};

    $mm->respond("plugins/domain_name/".$domain->registrar."/view", %rv);
}

sub register {
    my ($self, $mm) = @_;
    # Get a domain name
    my $domain = $mm->param("domainpart");
    my $tld    = $mm->param("tld");
    my %args = (tlds      => [Kirin::DB::TldHandler->retrieve_all],
                oldparams => $mm->{req}->parameters,
                fields => \@fieldmap,
               );
    if (!$domain or !$tld) { 
        return $mm->respond("plugins/domain_name/register", %args);
    }

    $domain =~ s/\.$//;
    if ($domain =~ /\./) { 
        $mm->message("Domain name was malformed");
        return $mm->respond("plugins/domain_name/register", %args);
    }

    my $tld_handler = Kirin::DB::TldHandler->retrieve($tld);
    if (!$tld_handler) {
        $mm->message("We don't handle that top-level domain");
        return $mm->respond("plugins/domain_name/register", %args);
    }
    $domain .= ".".$tld_handler->tld;

    # Check availability
    my %rv = $self->_get_reghandle($mm, $tld_handler->registrar);
    return $rv{response} if exists $rv{response};
    my $r = $rv{reghandle};
    if (!$r->is_available($domain)) {
        $mm->message("That domain is not available; please choose another");
    }
    else {
        $args{available} = 1;
    }

    # XXX Get rid of this. Abstract it away by providing a way to specify tld attributes and classes
    if ( $tld_handler->registrar eq 'Nominet' ) {
        $args{ukdomain} = 1;
        $args{types} = [Kirin::DB::RegType->retrieve_all()];
    }

    if (!$mm->param("register")) {
        $args{years} = [ $tld_handler->min_duration .. $tld_handler->max_duration ];
        return $mm->respond("plugins/domain_name/register", %args);
    }

    # Get contact addresses, nameservers and register
    %rv = $self->_get_register_args($mm, 0, $tld_handler, %args);
    return $rv{response} if exists $rv{response};

    my $years = $mm->param("years") =~ /\d+/ ? $mm->param("years") : 1;

    my $order = undef;
    if ( ! $mm->param('order') || ! ( $order = Kirin::DB::Orders->retrieve($mm->param('order') ) ) ) {
        my $price = $tld_handler->price * $years;
        my $invoice = $mm->{customer}->bill_for({
            description  => "Registration of domain $domain",
            cost         => $price
        });
        $order = Kirin::DB::Orders->insert( {
            customer    => $mm->{customer},
            order_type  => 'Domain Registration',
            module      => __PACKAGE__,
            parameters  => $json->encode( {
                rv         => \%rv,
                tld        => $tld,
                domain     => $domain,
                years      => $years,
            } ),
            invoice     => $invoice->id,
        });
        if ( ! $order ) {
            Kirin::Utils->email_boss(
                severity    => "error",
                customer    => $mm->{customer},
                context     => "Trying to create order for domain registration",
                message     => "Cannot create order entry for registration of $domain for $years years"
            );
            $mm->message("Our systems are unable to record your order");
            return $mm->respond("plugins/domain_name/register", %args);
        }
        $order->set_status("New Order");
        $order->set_status("Invoiced");
    }

    if ( $order->status eq 'Invoiced' ) {
        return $mm->respond("plugins/invoice/view", invoice => $order->invoice);
    }
                
    $self->order_view($mm, $order->id);
}

sub transfer {
    my ($self, $mm) = @_;
    # Get a domain name
    my $domain = $mm->param("domainpart");
    my $tld    = $mm->param("tld");
    my %args = (tlds      => [Kirin::DB::TldHandler->retrieve_all],
                oldparams => $mm->{req}->parameters,
                fields => \@fieldmap
               );
    if (!$domain or !$tld) { 
        return $mm->respond("plugins/domain_name/transfer", %args);
    }

    $domain =~ s/\.$//;
    if ($domain =~ /\./) { 
        $mm->message("Domain name was malformed");
        return $mm->respond("plugins/domain_name/transfer", %args);
    }

    my $tld_handler = Kirin::DB::TldHandler->retrieve($tld);
    if (!$tld_handler) {
        $mm->message("We don't handle that top-level domain");
        return $mm->respond("plugins/domain_name/transfer", %args);
    }
    $domain .= ".".$tld_handler->tld;

    # Check availability
    my %rv = $self->_get_reghandle($mm, $tld_handler->registrar);
    return $rv{response} if exists $rv{response};
    my $r = $rv{reghandle};
    if ($r->is_available($domain)) {
        $mm->message("That domain does not exist. Continue if you wish to register it.");
        return $mm->respond("plugins/domain_name/register", %args);
    }
    else {
        $args{available} = 1;
    }

    if (!$mm->param("transfer")) { 
        $args{years} = [ $tld_handler->min_duration .. $tld_handler->max_duration ];
        return $mm->respond("plugins/domain_name/transfer", %args);
    }

    # Get contact addresses, nameservers and register
    %rv = $self->_get_register_args($mm, 0, $tld_handler, %args);
    return $rv{response} if exists $rv{response};

    my $years = $mm->param("duration") =~ /\d+/ ? $mm->param("duration") : 1;
    my $order = undef;
    if ( ! $mm->param('order') || ! ( $order = Kirin::DB::Orders->retrieve($mm->param('order') ) ) ) {
        my $price = $tld_handler->price * $years / $tld_handler->duration;
        my $invoice = $mm->{customer}->bill_for({
            description  => "Transfer of domain $domain",
            cost         => $price
        });
        $order = Kirin::DB::Orders->insert( {
            customer    => $mm->{customer},
            order_type  => 'Domain Transfer',
            module      => __PACKAGE__,
            parameters  => $json->encode(
                rv         => \%rv,
                tld        => $tld,
                domain     => $domain,
                years      => $years,
            ),
            invoice     => $invoice->id,
        });
        if ( ! $order ) {
            Kirin::Utils->email_boss(
                severity    => "error",
                customer    => $mm->{customer},
                context     => "Trying to create order for domain transfer",
                message     => "Cannot create order entry for transfer of $domain for $years years"
            );
            $mm->message("Our systems are unable to record your order");
            return $mm->respond("plugins/domain_name/transfer", %args);
        }
        $order->set_status("New Order");
        $order->set_status("Invoiced");
    }

    if ( $order->status eq 'Invoiced' ) {
        return $mm->respond("plugins/invoice/view", invoice => $order->invoice);
    }
                
    $self->order_view($mm, $order->id);
}

sub renew {
    my ($self, $mm, $domainid) = @_;
    my %rv = $self->_get_domain($mm, $domainid);
    return $rv{response} if exists $rv{response};
    my ($domain, $handle) = ($rv{object}, $rv{reghandle});
    if (!$mm->param("duration")) {
        return $mm->respond("plugins/domain_name/renew", domain => $domain);
    }
    my $years = $mm->param("duration");
    my $price = $domain->tld_handler->price * $years;

    my $order = undef;
    if ( ! $mm->param('order') || ! ( $order = Kirin::DB::Orders->retrieve($mm->param('order')) ) ) {
        my $invoice = $mm->{customer}->bill_for({
            description  => "Renewal of of domain ".$domain->domain." for $years years",
            cost         => $price
        });

        $order = Kirin::DB::Orders->insert( {
            customer    => $mm->{customer},
            order_type  => 'Domain Renewal',
            module      => __PACKAGE__,
            parameters  => $json->encode({
                domain         => $domain,
                years          => $years
            }),
            invoice     => $invoice,
        });
        if ( ! $order ) {
            Kirin::Utils->email_boss(
                severity    => "error",
                customer    => $mm->{customer},
                context     => "Trying to create order for domain renewal",
                message     => "Cannot create order entry for renewal of $domain for $years years"
            );
            $mm->message("Our systems are unable to record your order");
            return $mm->respond("plugins/domain_name/renew", domain => $domain);
        }
        $order->set_status("New Order");
        $order->set_status("Invoiced");
    }

    if ( $order->status eq 'Invoiced' ) {
        return $mm->respond("plugins/invoice/view", invoice => $order->invoice);
    }
    $self->order_view($mm, $order->id);
}

sub process {
    my ($self, $id) = @_;

    my $order = Kirin::DB::Orders->retrieve($id);
    if ( ! $order || ! $order->invoice->paid ) { return; }

    if ( $order->module ne __PACKAGE__ ) { return; }

    my $op = $json->decode($order->parameters);

    my $tld_handler = Kirin::DB::TldHandler->retrieve($op->{tld});
    if ( ! $tld_handler ) {
        warn "TLD hander not available for ".$op->{tld};
        return;
    }

    my $domain = $op->{domain};

    my $mm = undef; 
    my $r = $self->_get_reghandle($mm, $tld_handler->registrar);

    if ( $order->order_type eq 'Domain Registration' ) {
        my $reg = undef;
        eval { $reg = $r->register(domain => $domain, %{$op->{rv}}); };
        if ( ! $reg ) {
            warn $@;
            return;
        }
        else {
            Kirin::DB::DomainName->create({
                customer       => $order->customer,
                domain         => $domain,
                registrar      => $tld_handler->registrar,
                tld_handler    => $tld_handler->id,
                billing        => $json->encode($op->{rv}->{billing}),
                admin          => $json->encode($op->{rv}->{admin}),
                technical      => $json->encode($op->{rv}->{technical}),
                nameserverlist => $json->encode($op->{rv}->{nameservers}),
                expires        => Time::Piece->new + * ONE_YEAR * $op->{years}
            });

            $order->set_status('Domain Registered');
            $order->set_status('Completed');
            return 1;
        }
    }
    elsif ( $order->order_type eq 'Domain Transfer' ) {


    }
    elsif ( $order->order_type eq 'Domain Renewal' ) {
        my $d = Kirin::DB::DomainName->search(domain => $domain,
            customer => $order->customer);
        if ( ! $d ) { return; }

        if ( ! $r->can('renew') ) {
            Kirin::Utils->email_boss(
                severity => "error",
                context  => "trying to get reghandle to renew $domain",
                message  => "Cannot find renew method in reg handle for $domain",
            );
            return;
        }

        eval { $r->renew(domain => $domain, years => $op->{years}) };
        if ( $@ ) {
            Kirin::Utils->email_boss(
                severity => "error",
                context  => "renewing domain $domain",
                message  => "Unable to renew domain with registry - $@",
            );
            return;
        }
        else {
            $domain->expires($domain->expires + ONE_YEAR * $op->{years});
            $domain->update();
            $order->set_status('Domain Renewed');
            $order->set_status('Completed');
            return 1;
        }
    }
}

sub _get_register_args {
    # Give me back: billing, admin, technical, nameservers, years
    my ($self, $mm, $just_contacts, $tld_handler, %args) = @_;
    my %rv;
    # Do the initial copy
    for my $field (map { $_->[1] } @{$args{fields}}) {
        for (qw/admin billing technical/) {
            my $answer = $mm->param($_."_".$field);
            $rv{$_}{$field} = $answer;
        }
    }

    if (!$just_contacts) {
        if ($mm->param("usedefaultns")) { 
            $rv{nameservers} = [
                Kirin->args->{primary_dns_server},
                Kirin->args->{secondary_dns_server},
            ]
        } else {
            # Check that they're IP addresses.
            my @ns = map { $mm->param($_) } qw(primary_ns secondary_ns);
            my $ok = 1;
            for (@ns) {
                if (!/^$RE{net}{domain}{-nospace}$/) { 
                    $mm->message("Nameserver is not a valid IP address");
                    $ok = 0;
                }
            }
            if ($ok) { $rv{nameservers} = \@ns }
        }
        if ( ! $mm->param("years") ) {
            $args{years} = [ $tld_handler->min_duration .. $tld_handler->max_duration ];
            $args{notsupplied}{years}++;
            
            $rv{response} = $mm->respond("plugins/domain_name/register", %args);
        }
    }

    # Now do some tidy-up
    my $cmess;
    $rv{admin} = $rv{billing} if $mm->param("copybilling2admin");
    $rv{technical} = $rv{billing}  if $mm->param("copybilling2technical");

    for (qw/admin billing technical/) {
        $rv{$_}{company} ||= "n/a";
        if ($rv{$_}{country} !~ /^([a-z]{2})$/i) { 
            delete $rv{$_}{country};
            $cmess++ || $mm->message("Country should be submitted as a two-letter ISO country code");
        }
        if (!Email::Valid->address($rv{$_}{email})) {
            delete $rv{$_}{email};
            $mm->message("Email address for $_ contact is not valid");
        }
        # Anything else?
    }
    if ( $tld_handler->registrar eq 'Nominet' ) {
        if ( ! $mm->param("type") ) {
            $mm->message("You must select a registrant type");
            $rv{response} = $mm->respond("plugins/domain_name/register", %args);
        }
        else {
            if ( $tld_handler->tld eq 'LTD' || $tld_handler->tld eq 'PLC' ) {
                if ( $mm->param("type") !~ /^(LTD|PLC)$/ ) {
                    $mm->message("Only a UK company registered with Companies House may register a .ltd.uk or .plc.uk domain");
                    $rv{response} = $mm->respond("plugins/domain_name/register", %args);
                }
            }
            if ( $mm->param("type") =~ /^(LTD|PLC)$/ ) {
                if ( ! $mm->param("cono") ) {
                    $mm->message("You must specify the Registered Company Number");
                    $rv{notsupplied}{cono}++;
                    $rv{response} = $mm->respond("plugins/domain_name/register", %args);
                }
                else {
                    $rv{admin}{"co-no"} = $mm->param("cono");
                }
            }
            $rv{admin}{type} = $mm->param("type");
        }
        if ( $mm->param("type") !~ /^(IND|FIND)$/ && $mm->param("opt-out") eq 'Y' ) {
            $mm->message("Only non-trading individuals may select WHOIS privacy");
            $rv{response} = $mm->respond("plugins/domain_name/register", %args);
        }
        $rv{admin}{"opt-out"} = $mm->param("opt-out");
    }

    # Final check for all parameters
    for my $field (map { $_->[1] } @{$args{fields}}) {
        for (qw/admin billing technical/) {
            if (! $rv{$_}{$field}) {
                next if $field eq 'trad-name' || $field eq 'Trading Name';
                $args{notsupplied}{"${_}_$field"}++;
                $rv{response} = 
                    $just_contacts ? 
                        $mm->respond("plugins/domain_name/change_contacts", %args)
                    :   $mm->respond("plugins/domain_name/register", %args);
            }
        }
    }
    return %rv;
}

sub _get_reghandle {
    my ($self, $mm, $reg) = @_;
    my $credentials = Kirin->args->{registrar_credentials}->{$reg};
    if (!$credentials) {
        return unless $mm;
        $mm->message("Internal error: Couldn't connect to that registrar");
        Kirin::Utils->email_boss(
            severity => "error",
            context  => "trying to contact registrar $reg",
            message  => "No credentials found! Set Kirin->args->{registrar_credentials}{$reg}"
        );
        return ( response => $self->list($mm) );
    }

    my $r = Net::DomainRegistration::Simple->new(
        registrar => $reg,
        %{$credentials},
    );
    if (!$r) {
        return unless $mm;
        $mm->message("Internal error: Couldn't connect to that registrar");
        Kirin::Utils->email_boss(
            severity => "error",
            context  => "trying to contact registrar $reg",
            message  => "Could not connect to registrar"
        );
        return ( response => $self->list($mm) );
    }
    return reghandle => $r;
}

sub _get_domain {
    my ($self, $mm, $domainid) = @_;
    my $d = Kirin::DB::DomainName->retrieve($domainid);
    if (!$d) { 
        $mm->message("That domain doesn't exist");
        return ( response => $self->list($mm) );
    }
    if ($d->customer != $mm->{customer}) {
        $mm->message("That's not your domain");
        return ( response => $self->list($mm) );
    }
    my %stuff = $self->_get_reghandle($mm, $d->registrar);
    return (response => $stuff{response}) if exists $stuff{response};
    return (object => $d, reghandle => $stuff{reghandle});
}

sub change_contacts {
    my ($self, $mm, $domainid) = @_;
    my %rv = $self->_get_domain($mm, $domainid);
    return $rv{response} if exists $rv{response};

    my ($domain, $handle) = ($rv{object}, $rv{reghandle});
    my %args = ( fields => \@fieldmap, domain => $domain );

    # Massage existing stuff into oldparams
    for my $ctype (qw/billing admin technical/) {
        my $it = $json->decode($rv{object}->$ctype);
        for (@fieldmap) {
            $args{oldparams}{$ctype."_".$_->[1]} = $it->{$_->[1]};
            $mm->{req}->parameters->{$ctype."_".$_->[1]} = $it->{$_->[1]};
        }
    }

    %rv = $self->_get_register_args($mm, 1, $domain->tld_handler, %args);
    use Data::Dumper; warn Dumper(\%rv);
    return $rv{response} if exists $rv{response};

    if ($mm->param("change") and $handle->change_contact(domain => $domain->domain, %rv)) {
        for (qw/billing admin technical/) {
            $domain->$_($json->encode($rv{$_}));
        }
        $domain->update;
        $mm->message("Contact updated successfully");
        return $self->list($mm);
    }
    $mm->respond("plugins/domain_name/change_contacts", %args);
}

sub change_nameservers {
    my ($self, $mm, $domainid) = @_;
    my %rv = $self->_get_domain($mm, $domainid);
    return $rv{response} if exists $rv{response};

    my ($domain, $handle) = ($rv{object}, $rv{reghandle});
    my @current = @{$json->decode($domain->nameserverlist)};
    my ($primary, $secondary) = map { $mm->param($_) } qw/primary_ns secondary_ns/;
    if ($mm->param("usedefaultns")) { 
        ($primary, $secondary) = (Kirin->args->{primary_dns_server},
            Kirin->args->{secondary_dns_server});
    }

    if ($primary and $secondary) { 
        # Check 'em
        if ($primary !~ /^$RE{net}{domain}{-nospace}$/
            or $secondary !~ /^$RE{net}{domain}{-nospace}$/) { 
            $mm->message("Nameserver address should be a hostname");
        } elsif ($handle->set_nameservers(domain => $domain->domain,
            nameservers => [ $primary, $secondary ])) {
            $domain->nameserverlist($json->encode([ $primary, $secondary ]));
            $domain->update;
            $mm->message("Nameservers changed");
            return $self->list($mm);
        } else {
            $mm->message("Your request could not be completed");
        }
    }
    $mm->respond("plugins/domain_name/change_nameservers",
        current => \@current,
        domain  => $domain
    );
}

sub revoke {
    my ($self, $mm, $domainid) = @_;
    my %rv = $self->_get_domain($mm, $domainid);
    return $rv{response} if exists $rv{response};

    my ($domain, $handle) = ($rv{object}, $rv{reghandle});
    if (!$mm->param("confirm")) {
        return $mm->respond("plugins/domain_name/revoke", domain => $domain);
    }
    if ( ! $handle->can("revoke") ) {
        $mm->message("It is not possible to revoke this type of domain registration");
        return $self->view($domain->id);
    }
    eval { $handle->revoke(domain => $domain->domain); };
    if ( ! $@ ) {
        $domain->delete;
        return $self->list($mm);
    }
    # Something went wrong
    $mm->message("Your request could not be processed");
    return $mm->respond("plugins/domain_name/revoke", domain => $domain);
}

sub _setup_db {
    shift->_ensure_table("domain_name");
    Kirin::DB::DomainName->has_a(tld_handler => "Kirin::DB::TldHandler");
    Kirin::DB::DomainName->has_a(expires => 'Time::Piece',
      inflate => sub { Time::Piece->strptime(shift, "%Y-%m-%d") },
      deflate => 'ymd',
    );
}

sub delete {
    my ($self, $mm, $id) = @_;
    if (!$mm->{user}->is_root) { return $mm->respond("403handler") }
    my %rv = $self->_get_domain($mm, $id);
    return $rv{response} if exists $rv{response};

    my ($domain, $handle) = ($rv{object}, $rv{reghandle});
    if (!$domain) {
        $mm->message('That domain is not in the database.');
        return $self->list($mm);
    }
    my $registered = undef;
    eval { $registered = $handle->domain_info($domain->domain); };
    if ( $registered ) {
        $mm->message("You cannot delete a domain that is still registered through us");
    }
    else {
        $domain->delete;
    }
    return $self->list($mm);
}

sub admin {
    my ($self, $mm) = @_;
    if (!$mm->{user}->is_root) { return $mm->respond("403handler") }
    if ( $mm->param("tld")) {
        if ($mm->param("create")) {
            if (!$mm->param("registrar") || 
            ! Kirin::DB::DomainRegistrar->retrieve($mm->param("registrar")) ) {
                $mm->message("Select a Registrar from the supplied list");
                goto done;
            }

            if (!$mm->param("tld")) {
                $mm->message("You must specify a valid domain TLD");
                goto done;
            }

            if ( ! Kirin::DB::DomainClass->retrieve($mm->param('registrant_class')) ||
                ! Kirin::DB::DomainClass->retrieve($mm->param('admin_class')) ||
                ! Kirin::DB::DomainClass->retrieve($mm->param('tech_class')) ) {
                $mm->message("You must select from the available contact classes");
                goto done;
            }


            if ( !$mm->param("price") ) {
                $mm->message("You must specify the annual price for the domain");
                goto done;
            }
            
            if ( ! $mm->param("min_duration") || ! $mm->param("max_duration") ) {
                $mm->message("You must specify the minimum and maximum registration period in years.");
                goto done;
            }
            
            my $handler = Kirin::DB::TldHandler->create({
                map { $_ => $mm->param($_) }
                    qw/tld registrar registrant_class admin_class 
                       tech_class price min_duration max_duration/
            });
            $mm->message("Handler created") if $handler;
        } elsif (my $id = $mm->param("edittld")) {
            my $handler = Kirin::DB::TldHandler->retrieve($id);
            if ($handler) {
                for (qw/tld registrar price min_duration max_duration/) {
                    next if ! $mm->param($_);
                    $handler->$_($mm->param($_));
                }
                $handler->update();
            }
        } elsif (my $id = $mm->param("deletetld")) {
             my $thing = Kirin::DB::TldHandler->retrieve($id);
             if ($thing) { $thing->delete; $mm->message("Handler deleted") }
        }
    }

    done:
    my @tlds = Kirin::DB::TldHandler->retrieve_all();
    $mm->respond("plugins/domain_name/admin", tlds => \@tlds);
}

sub admin_class_types {
    my ($self, $mm) = @_;

    if ( $mm->param('create') ) {
        if ( ! $mm->param('name') || ! $mm->param('value') ) {
            $mm->message("You must provide the name and value for the Class Type");
            goto done;
        }
        my $type = Kirin::DB::DomainClassType->create({
            map {$_ => $mm->param($_) } qw/name value/ });
        $mm->message("Class Type created") if $type;
    }
    elsif ( my $id = $mm->param('edit') && $mm->param('edit') =~ /^\d+$/ ) {
        my $type = Kirin::DB::DomainClassType->retrieve($id);
        if ( $type ) {
            for (qw/name value/) {
                next if ! $mm->param($_);
                $type->$_($mm->param($_));
            }
            $type->update();
        }
    }
    elsif ( my $id = $mm-param('delete') && $mm->param('delete') =~ /^\d+$/ ) {
        my $type = Kirin::DB::DomainClassType->retrieve($id);
        if ( $type ) {
            $type->delete;
            $mm->message("Class type deleted");
        }
    }

    my @types = Kirin::DB::DomainClassType->retrieve_all();
    $mm->respond("plugins/domain_name/admin_class_type", types => \@types);
}

sub admin_domain_class {
    my ($self, $mm) = @_;

    if ( $mm->param('create') ) {
        if ( ! $mm->param('name') || ! $mm->param('value') ) {
            $mm->message("You must provide the name and value for the Class");
            goto done;
        }
        my $type = Kirin::DB::DomainClass->create({
            map {$_ => $mm->param($_) } qw/name value condition/ });
        $mm->message("Domain Class created") if $type;
    }
    elsif ( my $id = $mm->param('edit') && $mm->param('edit') =~ /^\d+$/ ) {
        my $type = Kirin::DB::DomainClass->retrieve($id);
        if ( $type ) {
            for (qw/name value condition/) {
                next if ! $mm->param($_);
                $type->$_($mm->param($_));
            }
            $type->update();
        }
    }
    elsif ( my $id = $mm-param('delete') && $mm->param('delete') =~ /^\d+$/ ) {
        my $type = Kirin::DB::DomainClass->retrieve($id);
        if ( $type ) {
            $type->delete;
            $mm->message("Class deleted");
        }
    }

    my @class = Kirin::DB::DomainClass->retrieve_all();
    $mm->respond("plugins/domain_name/admin_class", classes => \@class);
}

sub admin_tld_handler {
    my ($self, $mm) = @_;

}

sub admin_registrar {
    my ($self, $mm) = @_;

}


sub _setup_db {
    my $self = shift;
    for my $table (qw/domain_name tld_handler domain_class 
        domain_class_attr domain_registrar domain_reg_attr/) {
        $self->_ensure_table($table);
    }
        
    Kirin::DB::DomainName->has_a(registrar => "Kirin::DB::DomainRegistrar");
    Kirin::DB::DomainName->has_a(customer => "Kirin::DB::Customer");

    Kirin::DB::TldHandler->has_a(registrar => "Kirin::DB::DomainRegistrar");
    Kirin::DB::DomainClass->has_a(tld_handler => "Kirin::DB::TldHandler");
    Kirin::DB::DomainClass->has_a(class_type => "Kirin::DB::DomainClassType");
    Kirin::DB::DomainClassAttr->has_a(domain_class => "Kirin::DB::DomainClass");

    Kirin::DB::TldHandler->has_many(classes => "Kirin::DB::DomainClass");
    Kirin::DB::DomainClass->has_many(attributes => "Kirin::DB::DomainClassAttr");

    Kirin::DB::DomainRegAttr->has_a(registrar => "Kirin::DB::DomainRegistrar");
    Kirin::DB::DomainRegistrar->has_many(attributes => "Kirin::DB::DomainRegAttr");
}

package Kirin::DB::DomainName;

sub sql{q/
CREATE TABLE IF NOT EXISTS domain_name ( id integer primary key not null,
    customer integer,
    domain varchar(255) NOT NULL, 
    registrar integer,
    registrar_id varchar(255),
    billing text,
    admin text,
    technical text,
    nameserverlist varchar(255),
    expires datetime
);

CREATE TABLE IF NOT EXISTS tld_handler ( id integer primary key not null,
    tld varchar(20),
    registrar integer,
    reg_class integer,
    admin_class integer,
    tech_class integer,
    price number(5,2),
    min_duration integer,
    max_duration integer
);

CREATE TABLE IF NOT EXISTS domain_class ( id integer primary key not null,
    tld_handler integer,
    class_type varchar(255),
    name varchar(255)
);

CREATE TABLE IF NOT EXISTS domain_class_attr ( id integer primary key not null,
    domain_class integer,
    name varchar(255),
    value varchar(255),
    condition text
);

CREATE TABLE IF NOT EXISTS domain_class_type (
    id integer primary key not null,
    name varchar(255),
    value varchar(255)
);    

CREATE TABLE IF NOT EXISTS domain_registrar (
    id integer primary key not null,
    name varchar(50),
    active integer
);

CREATE TABLE IF NOT EXISTS domain_reg_attr (
    id integer primary key not null,
    registrar integer,
    name varchar(255),
    value varchar(255),
    required integer
);    
/}

1;
