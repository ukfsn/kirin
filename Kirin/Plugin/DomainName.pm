package Kirin::Plugin::DomainName;
use Regexp::Common qw/net number/;
use Net::DomainRegistration::Simple;
use Net::Domain::ExpireDate;
use List::Util qw/sum/;
use strict;
use base 'Kirin::Plugin';
use Time::Seconds;
sub name      { "domain_name" }
sub default_action { "list" }
sub user_name {"Domain Names"}

use JSON;

my $json = JSON->new->allow_blessed->allow_nonref;

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

    $mm->respond("plugins/domain_name/".$domain->registrar->name."/view", %rv);
}

sub register {
    my ($self, $mm) = @_;
    # Get a domain name
    my $domain = $mm->param("domainpart");
    my $tld    = $mm->param("tld");
    my %args = (tlds      => [Kirin::DB::TldHandler->retrieve_all],
                oldparams => $mm->{req}->parameters
               );
    if (!$domain or !$tld) { 
        return $mm->respond("plugins/domain_name/register", %args);
    }

    $domain =~ s/\.$//;
    if (! Kirin::Validation->domain_name($domain) ) { 
        $mm->message("Selected domain name is not valid");
        return $mm->respond("plugins/domain_name/register", %args);
    }

    my $tld_handler = Kirin::DB::TldHandler->retrieve($tld);
    if (!$tld_handler) {
        $mm->message("We don't handle that top-level domain");
        return $mm->respond("plugins/domain_name/register", %args);
    }
    $args{tld} = $tld_handler;
    $domain .= ".".$tld_handler->tld;

    # Check availability
    my %rv = $self->_get_reghandle($mm, $tld_handler->registrar->name);
    return $rv{response} if exists $rv{response};
    my $r = $rv{reghandle};
    if (!$r->is_available($domain)) {
        $mm->message("That domain is not available; please choose another");
    }
    else {
        $args{available} = 1;
    }

    $args{contacts} = Kirin::DB::DomainContact->retrieve_all();
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
                oldparams => $mm->{req}->parameters
               );
    if (!$domain or !$tld) { 
        return $mm->respond("plugins/domain_name/transfer", %args);
    }

    $domain =~ s/\.$//;
    if (! Kirin::Validation->domain_name($domain)  ) { 
        $mm->message("Domain name is not valid");
        return $mm->respond("plugins/domain_name/transfer", %args);
    }

    my $tld_handler = Kirin::DB::TldHandler->retrieve($tld);
    if (!$tld_handler) {
        $mm->message("We don't handle that top-level domain");
        return $mm->respond("plugins/domain_name/transfer", %args);
    }
    $args{tld} = $tld_handler;
    $domain .= ".".$tld_handler->tld;

    # Check availability
    my %rv = $self->_get_reghandle($mm, $tld_handler->registrar->name);
    return $rv{response} if exists $rv{response};
    my $r = $rv{reghandle};
    if ($r->is_available($domain)) {
        $mm->message("That domain does not exist. Continue if you wish to register it.");
        return $mm->respond("plugins/domain_name/register", %args);
    }
    else {
        $args{expires} = expire_date($domain);
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
    my $r = $self->_get_reghandle($mm, $tld_handler->registrar->name);

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
                tld            => $tld_handler->tld,
                registrar      => $tld_handler->registrar,
                registrant     => $json->encode($op->{rv}->{registrant}),
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

sub contacts {
    my ($self, $mm, $id) = @_;
    my %args = ();

    # Build the list of possible contact fields
    my %fields = ();
    my @fields = ();
    for my $class ( Kirin::DB::DomainClass->retrieve_all() ) {
        for my $a ($class->attributes) {
            next if $fields{$a->name};
            push @fields, $a->name;
            $fields{$a->name} = $a->validation_type;
        }
    }
    $args{fields} = \@fields;

    my $contact = Kirin::DB::DomainContact->retrieve($id);
    if ( ! $contact ) {
        my %c = $self->_get_contact_details($mm, \%fields, \%args);
        goto done if $args{errors};
        $contact = Kirin::DB::DomainContact->insert({
            customer => $mm->{customer},
            name => $mm->param('name'),
            contact => $json->encode(%c)
        });
        $args{contact} = $contact;
    }
    if ( $contact && $contact->customer == $mm->{customer} ) {
        if ( $mm->param('edit') ) {
            my %c = $self->_get_contact_details($mm, \%fields, \%args);
            goto done if $args{errors};
            $contact->contact($json->encode(%c));
            $contact->update();
            $args{contact} = $contact;
            goto done;
        }
        elsif ( $mm->param('delete') && $contact->customer == $mm->{customer} ) {
            # first check whether it is being used 
            my @domains = Kirin::DB::DomainName->retrieve_from_sql(qq|
                registrant => $contact->id OR
                admin => $contact->id OR
                technical => $contact->id|
                );
            if ( scalar @domains > 0 ) {
                $mm->message("You cannot delete that domain contact. It is used on the following domains");
                foreach (@domains) {
                    $mm->message($_->domain);
                }
                goto done;
            }
            else {
                $contact->delete;
            }
        }
    }

    done:
    $mm->respond('plugins/domain_name/contacts', %args);
}

sub _get_contact_details {
    my ($self, $mm, $fields, $args) = @_;
    my %c = ();
    my $params = $mm->{req}->parameters();
    $args->{errors} = undef;

    if ( ! $mm->param('name') ) {
        $args->{errors}{name}++;
        $mm->message('Please provide a name for this contact');
    }
    for my $k (keys %$params) {
        if ( $k =~ /^contact_(.*)$/ ) {
            my $field = $1;
            next unless $fields->{$field};
            if ( ! Kirin::Validation->valid_thing($fields->{$field},
                    $mm->param('contact_'.$field ) ) ) {
                $mm->message($a->label.' is not valid');
                $args->{errors}{$field}++;
            }
            $args->{oldparams}{$field} = $mm->param('contact_'.$field);
            $c{$field} = $mm->param('contact_'.$field);
        }
    }
    return %c;
}

sub _get_register_args {
    # Give me back: registrant, admin, technical, nameservers, years
    my ($self, $mm, $just_contacts, $tld_handler, %args) = @_;
    my %rv = ();

    for my $class (qw/reg_class admin_class tech_class/) {
        my $c = $tld_handler->$class;
        my $prefix = 'registrant';
        $prefix = 'admin' if $class eq 'admin_class';
        $prefix = 'technical' if $class eq 'tech_class';
        my $contact = undef;

        if ( $mm->param($prefix.'_contact_id') ) {
            $contact = Kirin::DB::DomainContact->retrieve($mm->param($prefix.'_contact_id'));
            $rv{$prefix} = $json->decode($contact->contact);
        }
        # If customer provides additional/updated info...
        for my $field (map { $_->name } $c->attributes) {
            my $answer = defined $mm->param($prefix."_".$field) ?
                $mm->param($prefix."_".$field) :
                $args{oldparams}{$prefix.'_'.$field};
            $rv{$prefix}{$field} = $answer if ! defined $rv{$prefix}{$field};
        }
        $rv{admin} = $rv{registrant} if $mm->param("copyreg2admin");
        $rv{technical} = $rv{registrant}  if $mm->param("copyreg2technical");
        if ( ! $contact ) {
            $contact = Kirin::DB::DomainContact->insert({
                customer => $mm->{customer},
                name => $mm->param('name'),
                contact => $json->encode($rv{$prefix})
            });
        }

        if ( ! Kirin::Validation->validate_class($mm, $c, $prefix, \%rv, \%args) ) {
            $rv{response} = $just_contacts ?
                    $mm->respond("plugins/domain_name/change_contacts", %args)
                :   $mm->respond("plugins/domain_name/register", %args);
            return %rv;
        }
        $rv{$prefix} = $contact->id;
    }

    if (!$just_contacts) {
        if ($mm->param("usedefaultns")) {
            $args{oldparams}{"usedefaultns"} = 1;
            $rv{nameservers} = [
                Kirin->args->{primary_dns_server},
                Kirin->args->{secondary_dns_server},
            ]
        } else {
            $args{oldparams}{"usedefaultns"} = undef;
            $rv{nameservers} = undef;
            # Check that they're valid hosts or IPs.
            my @ns = map { $mm->param($_) } qw(primary_ns secondary_ns);
            my $ok = 1;
            for (@ns) {
                if ( ! Kirin::Validation->valid_thing('Host Name', $_) ) {
                    $mm->message("Nameserver is not valid");
                    $mm->respond("plugins/domain_name/register", %args);
                    $args{error}{nameservers}++;
                    $ok = undef;
                }
            }
            if ($ok) { $rv{nameservers} = \@ns }
        }

        if ( ! $mm->param("years") ) {
            $args{error}{years}++;
            $rv{response} = $mm->respond("plugins/domain_name/register", %args);
        }

        if ( $args{error} ) {
            $args{years} = [ $tld_handler->min_duration .. $tld_handler->max_duration ];
        }
    }
    return %rv;
}

sub _get_reghandle {
    my ($self, $mm, $reg) = @_;
    my %credentials;
    my $registrar = Kirin::DB::DomainRegistrar->search(name => $reg);
    return if ! $registrar;
    for my $a ($registrar->first->attributes) {
        $credentials{$a->name} = $a->value;
    }
    if (!%credentials) {
        return unless $mm;
        $mm->message("Internal error: Couldn't connect to that registrar");
        Kirin::Utils->email_boss(
            severity => "error",
            context  => "trying to contact registrar $reg",
            message  => "No attributes in DB"
        );
        return ( response => $self->list($mm) );
    }

    my $r = Net::DomainRegistration::Simple->new(
        registrar => $reg,
        %credentials
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
    return (response => $self->list($mm)) if $domainid !~ /^\d+$/;
    my $d = Kirin::DB::DomainName->retrieve($domainid);
    if (!$d) { 
        $mm->message("That domain doesn't exist");
        return ( response => $self->list($mm) );
    }
    if ($d->customer != $mm->{customer}) {
        $mm->message("That's not your domain");
        return ( response => $self->list($mm) );
    }
    my %stuff = $self->_get_reghandle($mm, $d->registrar->name);
    return (response => $stuff{response}) if exists $stuff{response};
    return (object => $d, reghandle => $stuff{reghandle});
}

sub change_contacts {
    my ($self, $mm, $domainid) = @_;
    my %rv = $self->_get_domain($mm, $domainid);
    return $rv{response} if exists $rv{response};

    my ($domain, $handle) = ($rv{object}, $rv{reghandle});
    my @tld_handler = Kirin::DB::TldHandler->search(tld => $domain->tld);
    my %args = ( tld => $tld_handler[0], domain => $domain );

    # Massage existing stuff into oldparams
    for my $ctype (qw/registrant admin technical/) {
        my $it = $json->decode($rv{object}->$ctype);
        my $class = 'reg_class';
        $class = 'admin_class' if $ctype eq 'admin';
        $class = 'tech_class' if $ctype eq 'technical';
        for ($tld_handler[0]->$class->attributes) {
            $args{oldparams}{$ctype.'_'.$_->name} = $it->{$_->name};
        }
    }
    %rv = $self->_get_register_args($mm, 1, $tld_handler[0], %args);
    return $rv{response} if $rv{response};

    if ($mm->param("change") and $handle->change_contact(domain => $domain->domain, %rv)) {
        for (qw/registrant admin technical/) {
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
            if ( ! Kirin::DB::DomainClass->retrieve($mm->param('reg_class')) ||
                ! Kirin::DB::DomainClass->retrieve($mm->param('admin_class')) ||
                ! Kirin::DB::DomainClass->retrieve($mm->param('tech_class')) ) {
                $mm->message("You must select from the available contact classes");
                goto done;
            }
            if ( !$mm->param("price") || $mm->param("price") !~ /^$RE{num}{real}{-places=>2}$/ ) {
                $mm->message("You must specify the annual price for the domain");
                goto done;
            }
            if ( ! $mm->param("min_duration") || ! $mm->param("max_duration") || 
                $mm->param("min_duration") !~ /^$RE{num}{real}{-places=>0}$/ ||
                $mm->param("max_duration") !~ /^$RE{num}{real}{-places=>0}$/ ) {
                $mm->message("You must specify the minimum and maximum registration period in years.");
                goto done;
            }
            my $handler = Kirin::DB::TldHandler->create({
                map { $_ => $mm->param($_) }
                    qw/tld registrar reg_class admin_class tech_class price 
                    min_duration max_duration trans_auth trans_renew/
            });
            $mm->message("Handler created") if $handler;
        } elsif ($mm->param("edittld")) {
            my $id = $mm->param("edittld");
            my $handler = Kirin::DB::TldHandler->retrieve($id);
            if ($handler) {
                if ( ! Kirin::DB::DomainClass->retrieve($mm->param('reg_class')) ||
                    ! Kirin::DB::DomainClass->retrieve($mm->param('admin_class')) ||
                    ! Kirin::DB::DomainClass->retrieve($mm->param('tech_class')) ) {
                    $mm->message("You must select from the available contact classes");
                    goto done;
                }
                if ( ! Kirin::DB::DomainRegistrar->retrieve($mm->param("registrar")) ) {
                    $mm->message("Select a Registrar from the supplied list");
                    goto done;
                }
                if ( !$mm->param("price") || $mm->param("price") !~ /^$RE{num}{real}{-places=>2}$/ ) {
                    $mm->message("You must specify the annual price for the domain");
                    goto done;
                }
                if ( ! $mm->param("min_duration") || ! $mm->param("max_duration") ||
                    $mm->param("min_duration") !~ /^$RE{num}{real}{-places=>0}$/ ||
                    $mm->param("max_duration") !~ /^$RE{num}{real}{-places=>0}$/ ) {
                    $mm->message("You must specify the minimum and maximum registration period in years.");
                    goto done;
                }
                for (qw/tld registrar reg_class admin_class
                        tech_class price min_duration max_duration/) {
                    $handler->$_($mm->param($_));
                }
                
                if ( $mm->param('trans_auth') ) {
                    $handler->trans_auth($mm->param('trans_auth'));
                }
                else { $handler->trans_auth(''); }

                if ( $mm->param('trans_renew') ) {
                    $handler->trans_renew($mm->param('trans_renew'));
                } else { $handler->trans_renew(''); }
                
                $handler->update();
            }
        } elsif ($mm->param("deletetld")) {
            my $id = $mm->param("deletetld");
            my $thing = Kirin::DB::TldHandler->retrieve($id);
            if ($thing) { $thing->delete; $mm->message("Handler deleted") }
        }
    }

    done:
    my @tlds = Kirin::DB::TldHandler->retrieve_all();
    my @registrars = Kirin::DB::DomainRegistrar->retrieve_all();
    my @classes = Kirin::DB::DomainClass->retrieve_all();
    $mm->respond("plugins/domain_name/admin", (
        tlds => \@tlds, registrars => \@registrars,
        classes => \@classes ));
}

sub admin_domain_class {
    my ($self, $mm) = @_;
    if (!$mm->{user}->is_root) { return $mm->respond("403handler") }

    if ( $mm->param('create') ) {
        for (qw/name label/) {
            if ( ! $mm->param($_) ) {
                $mm->message("You must supply $_");
                goto done;
            }
        }
        my $type = Kirin::DB::DomainClass->insert({
            map {$_ => $mm->param($_) } qw/name label/ });
        $mm->message("Domain Class created") if $type;
    }
    elsif ( $mm->param('edit') && $mm->param('edit') =~ /^\d+$/ ) {
        my $id = $mm->param('edit');
        my $class = Kirin::DB::DomainClass->retrieve($id);
        if ( $class ) {
            for (qw/name label/) {
                $class->$_($mm->param($_));
            }
            $class->update();
        }
    }
    elsif ( $mm->param('delete') && $mm->param('delete') =~ /^\d+$/ ) {
        my $id = $mm->param('delete');
        my $class = Kirin::DB::DomainClass->retrieve($id);
        if ( $class ) {
            $class->delete;
            $mm->message("Class deleted");
        }
    }

    my @class = Kirin::DB::DomainClass->retrieve_all();
    $mm->respond("plugins/domain_name/admin_class", classes => \@class);
}

sub admin_domain_class_attr {
    my ($self, $mm, $cid) = @_;
    if (!$mm->{user}->is_root) { return $mm->respond("403handler") }
    $self->admin_domain_class() if $cid !~ /^\d+$/;
    my $class = Kirin::DB::DomainClass->retrieve($cid); 
    if ( ! $class ) {
        return $self->admin_domain_class();
    }
    
    if ( $mm->param('create') ) {
        for (qw/name label validation_type/) {
            if ( ! $mm->param($_)) {
                $mm->message("You must supply $_");
                goto done;
            }
        }
        my $customer = $mm->{customer};
        my $cf = $mm->param('customer_field');
        if ( $mm->param('customer_field') && ! $customer->$cf ) {
            $mm->message("If you provide a customer field it must be from the list");
            $mm->param('customer_field') = undef;
        }
        if ( $mm->param('validation_type') && ! $Kirin::Validation::validations{$mm->param('validation_type')} ) {
            $mm->message("Select only from the list of available validation types");
            goto done;
        }
        my $attr = Kirin::DB::DomainClassAttr->insert({
            (map {$_ => $mm->param($_) } qw/name label customer_field required validation_type validation/),
            domain_class => $class->id
        });
        $mm->message("Attribute created");
    }
    elsif ($mm->param('edit') && $mm->param('edit') =~ /^\d+$/ ) {
        my $id = $mm->param('edit');
        my $attr = Kirin::DB::DomainClassAttr->retrieve($id);
        if ( $attr ) {
            for (qw/name label customer_field required validation_type validation/) {
                $attr->$_($mm->param($_));
                if ( $_ eq 'required' && $mm->param('required') ne 'on' ) {
                    $attr->required('');
                }
            }
            $attr->update();
            $mm->message("Attribute Updated");
        }
        $id = undef;
    }
    elsif ( $mm->param('delete') && $mm->param('delete') =~ /^\d+$/ ) {
        my $id = $mm->param('delete');
        my $attr = Kirin::DB::DomainClassAttr->retrieve($id);
        if ( $attr ) {
            $attr->delete;
            $mm->message("Attribute deleted");
        }
        $id = undef;
    }
    done:
    $mm->respond("plugins/domain_name/admin_class_attr", (
        class => $class,
        validation => [Kirin::Validation->names()]
    ));
}

sub admin_registrar {
    my ($self, $mm) = @_;
    if (!$mm->{user}->is_root) { return $mm->respond("403handler") }

    if ( $mm->param('create') ) {
        $mm->message("You must supply a name") if ! $mm->param('name');
        my $r = Kirin::DB::DomainRegistrar->insert({
            name => $mm->param('name'), active => $mm->param('active')
        });
        $mm->message("Registrar created") if $r;
    }
    elsif ( $mm->param('edit') && $mm->param('edit') =~ /^\d+$/ ) {
        my $id = $mm->param('edit');
        my $r = Kirin::DB::DomainRegistrar->retrieve($id);
        if ( $r ) {
            for (qw/name active/) {
                next if ! $mm->param($_);
                $r->$_($mm->param($_));
            }
            $r->update();
            $mm->message("Registrar Updated");
        }
    }
    elsif ( $mm->param('delete') && $mm->param('delete') =~ /^\d+$/ ) {
        my $id = $mm->param('delete');
        my $r = Kirin::DB::DomainRegistrar->retrieve($id);
        if ( $r ) {
            $r->delete;
            $mm->message("Registrar deleted");
        }
    }

    my @reg = Kirin::DB::DomainRegistrar->retrieve_all();
    $mm->respond("plugins/domain_name/admin_registrar", registrars => \@reg);
}

sub admin_registrar_attr {
    my ($self, $mm, $rid) = @_;
    if ( ! $rid || $rid !~ /^\d+$/ ) {
        return $self->admin_registrar();
    }
    my $registrar = Kirin::DB::DomainRegistrar->retrieve($rid);
    if ( ! $registrar ) {
        return $self->admin_registrar();
    }

    if ( $mm->param('create') ) {
        for (qw/name value/) {
            if ( ! $mm->param($_) ) {
                $mm->message("You must supply $_");
                goto done;
            }
        }
        my $attr = Kirin::DB::DomainRegAttr->insert({
            (map { $_ => $mm->param($_) } qw/name value/),
            registrar => $registrar->id
        });
        warn "Cannot create" if ! $attr;
        $mm->message("Attribute created");
    }
    elsif ($mm->param('edit') && $mm->param('edit') =~ /^\d+$/ ) {
        my $id = $mm->param('edit');
        my $a = Kirin::DB::DomainRegAttr->retrieve($id);
        if ( $a ) {
            for (qw/name value/) {
                next if ! $mm->param($_);
                $a->$_($mm->param($_));
            }
            $a->update();
            $mm->message("Registrar Updated");
        }
    }
    elsif ( $mm->param('delete') && $mm->param('delete') =~ /^\d+$/ ) {
        my $id = $mm->param('delete');
        my $a = Kirin::DB::DomainRegAttr->retrieve($id);
        if ($a) {
            $a->delete;
            $mm->message("Registrar Updated");
        }
    }
    done:
    $mm->respond("plugins/domain_name/admin_registrar_attr", registrar => $registrar);
}

sub _setup_db {
    my $self = shift;
    for my $table (qw/domain_name tld_handler domain_class 
        domain_class_attr domain_registrar domain_reg_attr
        domain_contact domain_registrar_contact/) {
        $self->_ensure_table($table);
    }
    
    Kirin::DB::DomainName->has_a(registrar => "Kirin::DB::DomainRegistrar");
    Kirin::DB::DomainName->has_a(customer => "Kirin::DB::Customer");
    Kirin::DB::DomainName->has_a(registrant => "Kirin::DB::DomainContact");
    Kirin::DB::DomainName->has_a(admin => "Kirin::DB::DomainContact");
    Kirin::DB::DomainName->has_a(technical => "Kirin::DB::DomainContact");
    Kirin::DB::DomainName->has_a(expires => 'Time::Piece',
      inflate => sub { Time::Piece->strptime(shift, "%Y-%m-%d") },
      deflate => 'ymd',
    );

    Kirin::DB::DomainContact->has_a(customer => "Kirin::DB::Customer");
    Kirin::DB::Customer->has_many(domain_contacts => "Kirin::DB::DomainContact");
    Kirin::DB::DomainRegistrarContact->has_a(domain_contact => "Kirin::DB::DomainContact");
    Kirin::DB::DomainContact->has_many(registry_id => "Kirin::DB::DomainRegistrarContact");
    Kirin::DB::DomainRegistrarContact->has_a(registrar => "Kirin::DB::DomainRegistrar");

    Kirin::DB::TldHandler->has_a(registrar => "Kirin::DB::DomainRegistrar");
    Kirin::DB::TldHandler->has_a(reg_class => "Kirin::DB::DomainClass");
    Kirin::DB::TldHandler->has_a(admin_class => "Kirin::DB::DomainClass");
    Kirin::DB::TldHandler->has_a(tech_class => "Kirin::DB::DomainClass");

    Kirin::DB::DomainClassAttr->has_a(domain_class => "Kirin::DB::DomainClass");

    Kirin::DB::DomainClass->has_many(attributes => "Kirin::DB::DomainClassAttr");

    Kirin::DB::DomainRegAttr->has_a(registrar => "Kirin::DB::DomainRegistrar");
    Kirin::DB::DomainRegistrar->has_many(attributes => "Kirin::DB::DomainRegAttr");
    Kirin::DB::DomainRegistrar->has_many(registry_contacts => "Kirin::DB::DomainRegistrarContact");
}

package Kirin::DB::DomainName;

sub sql{q/
CREATE TABLE IF NOT EXISTS domain_name ( id integer primary key not null,
    customer integer,
    domain varchar(255) NOT NULL, 
    tld varchar(10),
    registrar integer,
    registrant integer,
    admin integer,
    technical integer,
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
    max_duration integer,
    trans_auth integer,
    trans_renew integer
);

CREATE TABLE IF NOT EXISTS domain_contact ( id integer primary key not null,
    customer integer,
    name varchar(255),
    contact text
);

CREATE TABLE IF NOT EXISTS domain_registrar_contact (
    id integer primary key not null,
    domain_contact integer,
    registrar integer,
    registrar_id varchar(255)
);    

CREATE TABLE IF NOT EXISTS domain_class ( id integer primary key not null,
    name varchar(255),
    label varchar(255)
);

CREATE TABLE IF NOT EXISTS domain_class_attr ( id integer primary key not null,
    domain_class integer,
    name varchar(255),
    label varchar(255),
    customer_field varchar(255),
    required integer,
    validation_type varchar(255),
    validation text
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
    value varchar(255)
);    
/}

1;
