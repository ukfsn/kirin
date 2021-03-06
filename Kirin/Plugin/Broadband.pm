package Kirin::Plugin::Broadband;
use Time::Piece;
use Time::Seconds;
use Date::Holidays::EnglandWales;
use JSON;
use strict;
use base 'Kirin::Plugin';
use Net::DSLProvider;
sub user_name      { "Broadband" }
sub default_action { "list" }
use constant MAC_RE => qr/[A-Z0-9]{12,14}\/[A-Z]{2}[0-9]{2}[A-Z]/;
use constant ISO_DATE => qr/^[0-9]{4}-[0-9]{1,2}-[0-9]{1,2}$/;
my $dsl;

my $json = JSON->new->allow_blessed;

sub list {
    my ($self, $mm) = @_;
    my @bbs = Kirin::DB::Broadband->search(customer => $mm->{customer});
    $mm->respond("plugins/broadband/list", bbs => \@bbs);
}

sub view {
    my ($self, $mm, $id) = @_;
    if ( ! $id || $id !~ /^\d+%/ ){$self->list(); return;}
    my $bb = $self->_get_service($mm, $id);
    if (! $bb) { $self->list($mm); return; }
    my %details = eval { 
        $bb->provider_handle->service_view('service-id' => $bb->token);
    };
    if ($@) {
        warn $@;
        $mm->message('We are currently unable to retrieve details for this service from our supplier.');
    }
    my $service = { bb => $bb, details => \%details };
    return $mm->respond('plugins/broadband/'.$bb->service->provider.'/view', service => $service);
}

sub order {
    my ($self, $mm) = @_;
    my $clid = $mm->param("clid");
    $clid =~ s/\D*//g;
    my $mac  = uc $mm->param("mac");
    my $stage = $mm->param("stage");
    goto "stage_$stage" if $stage;

    stage_1:
        if (!$clid) { 
            return $mm->respond('plugins/broadband/get-clid');
        }
        if ($mac and $mac !~ MAC_RE) {
            $mm->message('That MAC was not well-formed; please check.');
            return $mm->respond('plugins/broadband/get-clid');
        } 

        # Have we run an availability check for this lately?
        my $search = Kirin::DB::BroadbandSearches->find_or_create( {
            customer => $mm->{customer},
            telno => $clid
        } );

        my %avail = ();     # This hash is what is returned to the customer
        my %services = ();

        if ( ! $search->result || $search->checktime < (time() - 2400) ) {
            my $dsl = Kirin::DB::Broadband->provider_handle( Kirin->args->{dsl_check_provider} );
            eval { %services = $dsl->services_available(
                cli => $clid, defined $mac ? (mac => $mac) : ()
            ); };
            if ( $@ ) {
                return $mm->respond('plugins/broadband/not-available',
                    reason => $@); # XXX Not a good idea to throw up the raw error perhaps?
            }
            $search->result($json->encode(\%services));
            $search->checktime(time());
            $search->update;
        }
        else {
            %services = %{$json->decode($search->result)};
        }

        my @services = Kirin::DB::BroadbandService->retrieve_all();
        foreach my $s (@services) {
            $avail{$s->sortorder} = {
                name => $s->name,
                id => $s->id,
                crd => defined $services{$s->code}->{first_date} ? 
                    $self->_dates($services{$s->code}->{first_date}) : 
                    $self->_dates(),
                price => $s->price,
                speed => defined $services{$s->code} ? $services{$s->code}->{max_speed} : undef,
                class => $s->class->name,
                options => $s->class->options,
            };
        }

        $mm->session->set("clid", $clid);
        $mm->session->set("mac", $mac) if $mac;
        
        return $mm->respond('plugins/broadband/signup', result => {
            services => \%avail,
            qualification => $services{qualification},
            vatrate => Kirin::Plugin->_get_vat_rate()
        });

    stage_2:
        # Previous step must supply service id, crd, ip address + any other options
        goto stage_1 unless $mm->param('service') =~ /^\d+$/;
        my $service = Kirin::DB::BroadbandService->retrieve($mm->param('service'));
        if ( ! $service ) {
            $mm->message('Please select from the available services');
            goto stage_1;
        }
        $mm->session->set("service", $service->id);

        my $crd = defined $mm->param('crd') ? $mm->param('crd'): $mm->param($mm->param('service').'_crd');

        if ( ! $self->_valid_date($crd) ) {
            $mm->message('We are unable to process an order for the selected date. Please select another date.');
            goto stage_1;
        }
        $mm->session->set("crd", $crd);

        my $options = { };
        for my $o ( $service->class->options ) {
            $options->{$o->code}++ if $mm->param($o->code);
        }
        $mm->session->set('options', $options);

        return $mm->respond('plugins/broadband/terms-and-conditions', order => {
            service => $service,
        });

    stage_3:

        if (!$mm->param('tc_accepted')) { # Back you go!
            $mm->param('Please accept the terms and conditions to complete your order'); 
            goto stage_2;
        }

        my $service = Kirin::DB::BroadbandService->retrieve($mm->session->get("service"));
        my $summary = {
            service => $service,
            clid    => $mm->session->get("clid"),
            crd     => $mm->session->get("crd"),
            options => $mm->session->get("options")
        };
        $summary->{mac} = $mm->session->get("mac") if $mm->session->get("mac");

        return $mm->respond('plugins/broadband/order-summary', {
            order => $summary,
            vatrate => Kirin::Plugin->_get_vat_rate()
        } );

    stage_4:
        if (!$mm->param('order_confirmed')) {
            $mm->param('We cannot process an order until you confirm the order details');
            goto stage_3;
        }

        my $order = Kirin::DB::Orders->insert( {
            customer    => $mm->{customer},
            order_type  => 'Broadband',
            module      => __PACKAGE__,
            status      => 'Building',
            parameters  => $json->encode( {
                service     => $service->id,
                clid        => $mm->session->get("clid"),
                mac         => $mm->session->get("mac"),
                crd         => $mm->session->get("crd"),
                options     => $mm->session->get("options")
            })
        });
        if ( ! $order ) {
            Kirin::Utils->email_boss(
                severity    => "error",
                customer    => $mm->{customer},
                context     => "Trying to create order for broadband",
                message     => "Cannot create order entry for broadband ".$service->name.' on '.$mm->session->get("clid")
            );
            $mm->message("Our system is unable to record the details of your order.");
            return $mm->respond("plugins/broadband/error");
        }

        $order->set_status("Ready");

        my $service = Kirin::DB::BroadbandService->retrieve($mm->session->get("service"));
        if ( $service->billed ) {
            my $price = $service->price;
            my $invoice = $mm->{customer}->bill_for({
                description => 'Broadband Order: '.$service->name.' on '.$mm->session->get("clid"),
                cost => $price
            });
            if ( ! $invoice ) {
                Kirin::Utils->email_boss(
                    severity    => "error",
                    customer    => $mm->{customer},
                    context     => "Trying to create broadband invoice",
                    message     => "Cannot create invoice for broadband ".$service->name.' on '.$mm->session->get("cli")
                );
                $mm->message("Our system is unable to record the details of your order.");
                return $mm->respond("plugins/broadband/error");
            }
            if ( ! $mac && $service->class->activation > 0 ) {
                $invoice->add_line_item(description => "Broadband Activation Charge", cost => $service->class->activation);
            }

            if ( $mm->session->get("mac") ) {
                my $search = Kirin::DB::BroadbandSearches->search( {
                    customer => $mm->{customer},
                    telno => $mm->session->get("cli")
                } );
                my $avail = $json->decode($search->first->result);

                my $charge = $service->class->migration;
                if ( $avail->{qualification}->{unbundled} ) {
                    $charge = $service->class->unbundledmigration;
                }

                if ( $charge > 0 ) {
                    $invoice->add_line_item(description => "Migration Charge", cost => $charge);
                }
            }

            for my $o (keys %{$mm->session->get("options")}) {
                next unless ($o->price > 0 || $o->setup > 0);
                if ($o->setup > 0) {
                    $invoice->add_line_item(description => $o->option . " Setup Charge", cost => $o->setup);
                }
                if ($o->price > 0) {
                    $invoice->add_line_item(description => $o->option, cost => $o->price);
                }
            }
            $order->invoice($invoice->id);
            $order->set_status("Invoiced");
            return $mm->respond("plugins/invoice/view", invoice => $order->invoice);
        }
        else {
            if ( $self->process($order->id) ) {
                $mm->respond("plugins/broadband/processed", $order);
            }
        }
}

sub process {
    my ($self, $id) = @_;
    return unless $id =~ /^\d+$/;

    my $order = Kirin::DB::Orders->retrieve($id);
    if ( ! $order || ( $order->invoice && ! $order->invoice->paid ) ) {
        return;
    }
    if ( $order->module ne __PACKAGE__ ) { return; }
    return if ( $order->status ne 'Ready' || $order->status ne 'Paid' );
    
    my $op = $json->decode($order->parameters);
    my $customer = Kirin::DB::Customer->retrieve($op->customer);
    my $service = Kirin::DB::BroadbandService->retrieve($op->service);
    return if ! $service;

    my $handle = Kirin::DB::Broadband->provider_handle($service->class->provider);
    # XXX Verify the order details are valid

    # XXX place the order
    my $orderid = undef;
    my $serviceid = undef;
    my %order = (
        "client-ref" => $service->id,
        "prod-id" => $service->code,
        "cli" => $op->{clid},
        crd => $op->{crd},
        "routed-ip" => defined $op->{ip} ? $op->{ip} : 'N',
        "allocation-size" => defined $op->{ip} ? $op->{ip} : '',
        totl => 'Y',
        topup => 'TOPUP', # XXX should be a configurable option
        "payment-method" => 2, # XXX should be a configurable option
        "initial-payment" => "DirectDebit", # XXX should be a configurable option
        "ongoing-payment" => "DirectDebit", # XXX should be a configurable option
        "contract-term" => 1, # XXX should be a class setting?
        "billing-period" => "Monthly", # XXX should be a configurable option
        "isp-name" => "Enta", # XXX is this needed?
        linespeed => "RA24", # XXX needs to come from qualification data
        title => $customer->title,
        forename => $customer->forename,
        surname => $customer->surname,
        company => $customer->org,
        street => $customer->address,
        city => $customer->town,
        county => $customer->county,
        postcode => $customer->postcode,
        telephone => $customer->phone,
        email => $customer->email,
        fax => $customer->fax,
        );
    if ( $customer->bb_customer_no ) {
        $order{"customer-id"} = $customer->bb_customer_no;
    }
    else {
        $order{"customer-id"} = "New";
        my %billing = (
            ctitle => $customer->title,
            cforename => $customer->forename,
            csurname => $customer->surname,
            ccompany => $customer->org,
            cstreet => $customer->address,
            ccity => $customer->town,
            ccounty => $customer->county,
            cpostcode => $customer->postcode,
            ctelephone => $customer->phone,
            cemail => $customer->email,
            cfax => $customer->fax,
            "customer-id" => "New",
        );
        @order{keys %billing} = values %billing;
    }
    eval { ($orderid, $serviceid) = $handle->order( %order ); };
    if ( $@ ) {
        Kirin::Utils->email_boss(
            severity    => "error",
            customer    => $order->customer,
            context     => "Trying to please broadband order",
            message     => "Cannot place broadband order $id ".$service->name.' on '.$op->{clid} . ' Error: '. $@
            );
        return;
    }
    
    my $bb = Kirin::DB::Broadband->insert ( {
        customer => $order->customer,
        telno => $op->{clid},
        service => $op->service,
        token => $serviceid,
        options => $op->options,
        status => 'Submitted'
    });
    $bb->record_event('order', 'Order Submitted');
    $order->set_status('Submitted');
    return 1;
}

sub request_mac {
    my ($self, $mm, $id) = @_;
    return unless $id =~ /^\d+$/;
    my $bb = $self->_get_service($mm, $id);
    if ( ! $bb ) { $self->list($mm); return; }

    if ($bb->status !~ /^live/) { 
        $mm->message('You cannot request a MAC for a service that is not live'); 
        return $self->view($mm, $id);
    }

    my %out = eval {
        $bb->provider_handle->request_mac('service-id' => $bb->token,
            reason => 'EU wishes to change ISP');
    };

    if ($@) { 
        $mm->message('An error occurred and your request could not be completed');
    }
    $bb->record_event('mac', 'MAC Requested');

    $mm->respond('plugins/broadband/mac-requested',
        mac_information => \%out # Template will sort out requested/got
    );
}

sub password_change {
    my ($self, $mm, $id) = @_;
    return unless $id =~ /^\d+$/;
    my $bb = $self->_get_service($mm, $id);
    if ( ! $bb ) { $self->list($mm); return; }
    
    my $pass = $mm->param('password1');
    if (!$pass) {
        $mm->message('Please enter your new password'); goto fail;
    }
    if ($pass ne $mm->param('password2')) {
        $mm->message('Passwords do not match'); goto fail;
    }
    if (!$self->_validate_password($mm, $pass)) { goto fail; }

    my $ok = $bb->provider_handle->change_password('service-id' => $bb->token,
        password => $pass);
    if ($ok) { 
        $bb->record_event('password', 'Password Changed');
        $mm->message('Password successfully changed: please remember to update your router settings!');
    } else { 
        $mm->message('Password WAS NOT changed');
    }
    return $self->view($mm, $id);

    fail: return $mm->respond('plugins/broadband/password_change');
}

sub regrade {
    my ($self, $mm, $id) = @_;
    return unless $id =~ /^\d+$/;
    my $bb = $self->_get_service($mm, $id);
    if ( ! $bb ) { $self->list($mm); return; }

    my $new_product = $mm->param('newproduct'); # XXX
    my %out;
    if ($new_product) { 
        %out = eval {
            $bb->provider_handle->regrade('service-id' => $bb->token,
                                'prod-id' => $new_product);
        };
        if ($@) { 
            $mm->message('An error occurred and your request could not be completed');
        }
        $bb->record_event('regrade', "Order to regrade to $new_product");
    }
    $mm->respond('plugins/broadband/regrade',
        information => \%out,
        service => $bb
    );
}

sub cancel { 
    my ($self, $mm, $id) = @_;
    return unless $id =~ /^\d+$/;
    my $bb = $self->_get_service($mm, $id);
    if ( ! $bb ) { $self->list($mm); return; }

    if (!$mm->param('date') || ! $self->_valid_date($mm->param('date'))) {
        $mm->message('Please choose a date for cancellation');
        return $mm->respond('plugins/broadband/cancel', cancel => {
            service => $id,
            dates => $self->_dates
        } ); 
    }

    if ( ! $mm->param('confirm') ) {
    return $mm->respond('plugins/broadband/confirm-cancel', cancel => { 
        date => $mm->param('date'),
        service => $id
        } );
    }
    
    my $out = eval {
        $bb->provider_handle->cease('service-id' => $bb->token,
            reason => 'This service is no longer required',
            crd    => $mm->param('date')
        ); 
    };
    if ($@) { 
        $mm->message("An error occurred and your request could not be completed: $@"); # XXX not a good idea to send raw error
        return $self->view($mm, $id);
    }
    $bb->status('live-ceasing');
    $bb->record_event('cease', 'Cease order placed');

    # XXX $out may contain an order reference for the cease which needs to
    # XXX needs to be recorded

    $mm->message('Cease request sent to DSL provider');
    $self->view($mm, $id);
}

sub interleaving {
    my ($self, $mm, $id) = @_;
    return unless $id =~ /^\d+$/;
    my $bb = $self->_get_service($mm, $id);
    if ( ! $bb ) { $self->list($mm); return; }

    # Not all providers enable interleaving changes
    if ( ! $bb->provider_handle->can('interleaving') ) {
        $mm->message('It is not possible to change interleaving on this service');
        $self->view($mm, $id);
    }

    if ( $mm->params('interleaving') !~ /^(Yes|No|Auto)$/ ) {
        $mm->message('You can only select from the available options');
        $self->view($mm, $id);
    }

    my $status = undef;
    eval { $status = $bb->provider_handle->interleaving(
        'service-id' => $bb->token, 
        interleaving => $mm->params('interleaving')
        );
    };
    if ($@) {
        $mm->message('It has not been possible to change the interleaving option');
        return $self->view($mm, $id);
    }

    $bb->record_event('modify', 'Change interleaving option');

    $mm->message('Order placed to change interleaving');
    $self->view($mm, $id);
}

sub sessions {
    my ($self, $mm, $id) = @_;
    return unless $id =~ /^\d+$/;
    my $bb = $self->_get_service($mm, $id);
    if ( ! $bb ) { $self->list($mm); return; }

    my @sessions = ();
    eval { @sessions = $bb->provider_handle->session_log(
        'service-id' => $bb->token,
        rows => 5 );
    };
    if ($@) {
        $mm->message('Cannot obtain session history information');
        return $self->view($mm, $id);
    }

    $mm->respond('plugins/broadband/sessions', sessions => \@sessions);
}

sub usage {
    my ($self, $mm, $id) = @_;
    return unless $id =~ /^\d+$/;
    my $bb = $self->_get_service($mm, $id);
    if ( ! $bb ) { $self->list($mm); return; }

}

sub usagehistory {
    my ($self, $mm, $id) = @_;
    return unless $id =~ /^\d+$/;
    my $bb = $self->_get_service($mm, $id);
    if ( ! $bb ) { $self->list($mm); return; }

}

sub events {
    my ($self, $mm, $id) = @_;
    return unless $id =~ /^\d+$/;
    my $bb = $self->_get_service($mm, $id);
    if ( ! $bb ) { $self->list($mm); return; }

    my @events = Kirin::DB::BroadbandEvent->search(broadband => $id);
    $mm->respond('plugins/broadband/events', events => \@events);    
}

sub _get_service {
    my ( $self, $mm, $id ) = @_;
    return unless $id =~ /^\d+$/;

    my $bb = Kirin::DB::Broadband->retrieve($id);
    if ( ! $bb ) { return; }
    
    if ( $mm->{user}->is_root || $bb->customer eq $mm->{customer} ) {
        return $bb;
    }
    return;
}

sub admin {
    my ($self, $mm) = @_;
    if (!$mm->{user}->is_root) { return $mm->respond('403handler') }

    my $id = undef;

    if ($mm->param('create')) {
        for (qw/name code class price sortorder/) {
            if ( ! $mm->param($_) ) {
                $mm->message("You must specify the $_ parameter");
            }
            $mm->respond('plugins/broadband/admin');
        }

        my $new = Kirin::DB::BroadbandService->insert({
            map { $_ => $mm->param($_) } qw/name code class price sortorder/
        });
        $mm->message('Broadband Service Added');
    }

    elsif ($id = $mm->param('editproduct')) {
        my $product = Kirin::DB::BroadbandService->retrieve($id);
        if ( $product ) {
            for (qw/name code class price sortorder/) {
                $product->$_($mm->param($_));
            }
            $product->update();
        }
        $mm->message('Broadband Service Updated');
    }

    elsif ($id = $mm->param('deleteproduct')) {
        my $product = Kirin::DB::BroadbandService->retrieve($id);
        if ( $product ) { $product->delete(); $mm->message('Broadband Service Deleted'); }
    }
    my @products = Kirin::DB::BroadbandService->retrieve_all();
    my @classes = Kirin::DB::BroadbandClass->retrieve_all();

    $mm->respond('plugins/broadband/admin', admin => {
        products => \@products,
        classes => \@classes
    });
}

sub admin_options {
    my ($self, $mm) = @_;
    if (!$mm->{user}->is_root) { return $mm->respond('403handler') }
    my $id = undef;
    if ($mm->param('create')) {
        for (qw/class option code value price setup/) {
            if ( ! $mm->param($_) ) {
                $mm->message("You must specify the $_ parameter");
            }
            $mm->respond('plugins/broadband/admin');
        }
        my $new = Kirin::DB::BroadbandOption->insert({
            map { $_ => $mm->param($_) } qw/class option code value price setup/
        });
        $mm->message('Broadband Service Option Added');
    }
    elsif ($id = $mm->param('editoption')) {
        if ( $id !~ /^\d+$/ ) {
            $mm->message('Option ID not numeric. Do not change form elements');
            next;
        }
        my $option = Kirin::DB::BroadbandOption->retrieve($id);
        if ( $option ) {
            for (qw/class option code value price setup/) {
                $option->$_($mm->param($_));
            }
            $option->update();
        }
        $mm->message('Broadband Option Updated');
    }
    elsif ($id = $mm->param('deleteoption')) {
        my $option = Kirin::DB::BroadbandOption->retrieve($id);
        if ( $option ) { $option->delete(); $mm->message('Broadband Option Deleted'); }
    }
    my @options = Kirin::DB::BroadbandOption->retrieve_all();
    my @classes = Kirin::DB::BroadbandClass->retrieve_all();
    my $classes = { };
    for my $c (@classes) {
        $classes->{$c->id} = {
            name => $c->name,
            provider => $c->provider
        };
    }
    $mm->respond('plugins/broadband/admin_options', opt => {
        options => \@options,
        classes => $classes
    });
}

sub admin_class {
    my ($self, $mm) = @_;
    if (!$mm->{user}->is_root) { return $mm->respond('403handler') }
    my $id = undef;
    if ($mm->param('create')) {
        for (qw/name provider activation migration unbundledmigration cease/) {
            if ( ! $mm->param($_) ) {
                $mm->message("You must specify the $_ parameter");
            }
            $mm->respond('plugins/broadband/admin');
        }
        my $new = Kirin::DB::BroadbandClass->insert({
            map { $_ => $mm->param($_) } qw/name provider activation migration unbundledmigration cease/
        });
        $mm->message('Broadband Service Class Added');
    }
    elsif ($id = $mm->param('editclass')) {
        if ( $id !~ /^\d+$/ ) {
            $mm->message('Class ID not numeric. Do not change form elements');
            next;
        }
        my $class = Kirin::DB::BroadbandClass->retrieve($id);
        if ( $class ) {
            for (qw/name provider activation migration unbundledmigration cease/) {
                $class->$_($mm->param($_));
            }
            $class->update();
        }
        $mm->message('Broadband Class Updated');
    }
    elsif ($id = $mm->param('deleteclass')) {
        my $class = Kirin::DB::BroadbandClass->retrieve($id);
        if ( $class ) { $class->delete(); $mm->message('Broadband Class Deleted'); }
    }
    my @classes = Kirin::DB::BroadbandClass->retrieve_all();
    $mm->respond('plugins/broadband/admin_class', classes => \@classes);
}

sub _setup_db {
    my $self = shift;
    my $p = Kirin->args->{dsl_check_provider};
    $dsl = "Net::DSLProvider::".ucfirst($p);
    $dsl->require or die "Can't find a provider module for $p:$@";

    $dsl->new( \%{Kirin->args->{dsl_credentials}->{$p}} ); 

    $self->_ensure_table('broadband');
    $self->_ensure_table('broadband_service');
    $self->_ensure_table('broadband_class');
    $self->_ensure_table('broadband_usage');
    $self->_ensure_table('broadband_searches');
    $self->_ensure_table('broadband_option');
    $self->_ensure_table('broadband_service_option');

    Kirin::DB::Broadband->has_a(customer => "Kirin::DB::Customer");
    Kirin::DB::Broadband->has_a(service => "Kirin::DB::BroadbandService");
    Kirin::DB::BroadbandService->has_a(class => "Kirin::DB::BroadbandClass");
    Kirin::DB::Customer->has_many(broadband => "Kirin::DB::Broadband");
    Kirin::DB::Customer->has_many(bb_search => "Kirin::DB::BroadbandSearches");
    Kirin::DB::BroadbandEvent->has_a(broadband => "Kirin::DB::Broadband");
    Kirin::DB::Broadband->has_many(events => "Kirin::DB::BroadbandEvent");
    Kirin::DB::BroadbandUsage->has_a(broadband => "Kirin::DB::Broadband");
    Kirin::DB::Broadband->has_many(usage_reports => "Kirin::DB::BroadbandUsage");
    Kirin::DB::BroadbandOption->has_a(class => "Kirin::DB::BroadbandClass");
    Kirin::DB::BroadbandClass->has_many(options => "Kirin::DB::BroadbandOption");
    Kirin::DB::BroadbandServiceOption->has_a(service => "Kirin::DB::BroadbandService");
    Kirin::DB::BroadbandServiceOption->has_a(option => "Kirin::DB::BroadbandOption");
    Kirin::DB::BroadbandService->has_many(service_option => "Kirin::DB::BroadbandServiceOption");
    Kirin::DB::BroadbandEvent->has_a(event_date => 'Time::Piece',
      inflate => sub { Time::Piece->strptime(shift, "%Y-%m-%d") },
      deflate => 'ymd',
    );
}

sub _dates {
    my $self = shift;
    my $first_date = shift;
    my $start = Time::Piece->new() + ONE_WEEK;
    while ( ! $self->_valid_date($start->ymd) ) {
        $start += ONE_DAY;
    }

    if ( $first_date && $first_date =~ ISO_DATE ) {
        $start = Time::Piece->strptime($first_date, "%F");
    }
    my $end = $start + ONE_MONTH;
    my @dates;
    while ( $start < $end ) {
        push @dates, $start->epoch
            unless ($start->wday == 1 || $start->wday == 7) 
                    || is_holiday($start->ymd);
        $start += ONE_DAY;
    }
    return \@dates;
}

sub _valid_date {
    my ($self, $date) = @_;
    return if ( ! $date || $date !~ ISO_DATE );
    my $start = Time::Piece->new();

    # We need to be certain that the effective start date is 5 clear
    # working days hence.
    my $count = 5;
    while ( $count > 0 ) {
        if ($start->wday == 1 || $start->wday == 7 || is_holiday($start->ymd)) {
            $start += ONE_DAY;
        }
        else {
            $start += ONE_DAY;
            $count --;
        }
    }

    my $end = $start + ONE_MONTH;
    my $d = Time::Piece->strptime($date, "%F");
    if ( $d < $start || $d > $end ) {
        return;
    }
    
    return 1;
}

package Kirin::DB::Broadband;

sub provider_handle {
    my $self = shift;
    my $p = shift || $self->service->class->provider;
    my $module = "Net::DSLProvider::".ucfirst($p);
    $module->require or die "Can't find a provider module for $p:$@";
    
    $module->new( Kirin->args->{dsl_credentials}->{$p} ); 
}

sub get_bandwidth_for {
    my ($self, $year, $mon, $replace) = @_;
    $year ||= 1900 + (localtime)[5];
    $mon  ||= 1    + (localtime)[4];
    $mon = sprintf("%02d", $mon);
    my ($bw) = $self->usage_reports(year => $year, month => $mon);
    if ($bw and !$replace) {
        return ($bw->input, $bw->output);
    }
    my %summary =  ();
    eval { %summary = $self->provider_handle->usage_summary(
        "service-id" => $self->token,
        year => $year,
        month => $mon
    ); };
    if ( $@ ) {
        warn $@; # XXX maybe do something 
        return;
    }
    if ($bw) { 
        $bw->input($summary{"total-input-octets"});
        $bw->output($summary{"total-output-octets"});
    } else {
        $self->add_to_usage_reports({
            year => $year,
            month => $mon,
            input => $summary{"total-input-octets"},
            output => $summary{"total-output-octets"},
        });
    }
    return ($summary{"total-input-octets"}, $summary{"total-output-octets"});
}

sub _service_details {
    my $self = shift;
    my %details = eval {
        $self->provider_handle->service_view('service-id' => $self->token);
    };
    if ( $@ ) {
        warn $@; # XXX maybe should do something more than just warn
        return;
    }
    return %details;
}

sub record_event {
    my ($self, $class, $desc ) = @_;
    if ( ! $class || ! $desc ) { return; }

    my $event = Kirin::DB::BroadbandEvent->create({
            broadband   => $self->id,
            timestamp   => Time::Piece->new(),
            class       => $class,
            token       => $self->token,
            description => $desc,
        });

    if ( ! $event ) {
        Kirin::Utils->email_boss(
            severity    => 'error',
            customer    => $self->customer,
            context     => 'event',
            message     => "Unable to record $class event - $desc",
        );
        
        return;
    }
    return 1;
}

sub sql {q/
CREATE TABLE IF NOT EXISTS broadband (
    id integer primary key not null,
    customer integer,
    telno varchar(12),
    service integer,
    options text,
    token varchar(255),
    status varchar(255)
);

CREATE TABLE IF NOT EXISTS broadband_event (
    id integer primary key not null,
    broadband integer,
    event_date datetime,
    token varchar(255),
    class varchar(255),
    description text
);

CREATE TABLE IF NOT EXISTS broadband_usage (
    id integer primary key not null,
    broadband integer,
    year integer,
    month integer,
    input integer,
    output integer    
);

CREATE TABLE IF NOT EXISTS broadband_service (
    id integer primary key not null,
    provider varchar(255),
    code varchar(255),
    name varchar(255),
    price decimal(5,2),
    sortorder integer,
    billed integer,
    class integer,
);

CREATE TABLE IF NOT EXISTS broadband_service_option (
    id integer primary key not null,
    service integer,
    option integer
);    

CREATE TABLE IF NOT EXISTS broadband_class (
    id integer primary key not null,
    name varchar(255),
    provider varchar(255),
    activation decimal(5,2),
    migration decimal(5,2),
    unbundledmigration decimal(5,2),
    cease decimal(5,2)
);

CREATE TABLE IF NOT EXISTS broadband_option (
    id integer primary key not null,
    class integer,
    option varchar(255),
    code varchar(255),
    value varchar(255),
    price decimal(5,2),
    setup decimal(5,2),
);

CREATE TABLE IF NOT EXISTS broadband_searches (
    id integer primary key not null,
    customer integer,
    checktime timestamp,
    telno varchar(12),
    postcode varchar(9),
    result text
);

/}
1;
