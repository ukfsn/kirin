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
my $murphx;

my $json = JSON->new->allow_blessed;

sub list {
    my ($self, $mm) = @_;
    my @bbs = Kirin::DB::Broadband->search(customer => $mm->{customer});
    $mm->respond("plugins/broadband/list", bbs => \@bbs);
}

sub view {
    my ($self, $mm, $id) = @_;
    if ( ! $id ){$self->list(); return;}
    my $bb = $self->_get_service($mm, $id);
    if (! $bb) { $self->list($mm); return; }
    my %details = eval { 
        $bb->provider_handle->service_view('service-id' => $bb->token);
    };
    if ($@) {
        warn $@;
        $mm->message('We are currently unable to retrieve details for this service.');
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

        my %avail = ();
        my @services = ();

        if ( ! $search->result || $search->checktime < (time() - 2400) ) {
            my $murphx = Kirin::DB::Broadband->provider_handle("murphx");
            eval { @services = $murphx->services_available(
                cli => $clid, qualification => 1,
                defined $mac ? (mac => $mac) : ()
            ); };
            if ( $@ ) {
                return $mm->respond('plugins/broadband/not-available',
                    reason => $@);
            }
            $search->result($json->encode(\@services));
            $search->checktime(time());
            $search->update;
        }
        else {
            @services = @{$json->decode($search->result)};
        }

        my $qdata = shift @services; # $qdata is a hashref of BTW services

        # XXX Deal with the qdata and offer BT based services for non-Murphx providers
        # We need to verify whether we can supply 2plus (annex m?) and fttc services

        # This part is Enta specific
        my $linespeeds = { ra8 => {
            description => 'ADSL Up to 8Mb/s',
            speed => $qdata->{'max'}->{'down_speed'}
            },
            topspeed => { adsl => {
                speed => $qdata->{'max'}->{'down_speed'},
                type => 'ADSL MAX'
            } }
        };
        if ( $qdata->{'2plus'} ) {
            $linespeeds->{'ra24'} = {
                description => 'ADSL2+ Up to 24Mb/s',
                speed => $qdata->{'2plus'}->{'down_speed'},
            };
            if ( $qdata->{'2plus'}->{'annexm'} ) {
                $linespeeds->{'ra24'}->{'annex_m'} = $qdata->{'2plus'}->{'annexm'};
            }
            $linespeeds->{topspeed}->{adsl} = {
                speed => $qdata->{'2plus'}->{'down_speed'},
                type => 'ADSL 2+'
            };
        }
        if ( $qdata->{'fttc'} ) {
            $linespeeds->{'fttc'} = {
                description => 'FTTC Up to 40Mb/s',
                speed => $qdata->{'fttc'}->{'down_speed'},
                upspeed => $qdata->{'fttc'}->{'up_speed'}
            };
            $linespeeds->{topspeed}->{fttc} = {
                speed => $qdata->{'fttc'}->{'down_speed'},
                type => 'FTTC' 
            };
        }

        # This part is Enta specific
        my @enta_services = Kirin::DB::BroadbandService->search(provider => 'Enta');
        foreach ( @enta_services ) {
            next if $_->name =~ /FTTC/ && ! $linespeeds->{'fttc'};
            $avail{$_->sortorder} = {
                name => $_->name,
                id => $_->id,
                crd => $self->_dates($qdata->{classic}->{first_date}),
                price => $_->price,
                options => $json->decode($S[0]->options),
            };
            if ( $linespeeds->{'fttc'} ) {
                $avail{$_->sortorder}->{speed} = $linespeeds->{'fttc'}->{speed};
            }
            elsif ( $linespeeds->{'ra24'} ) {
                $avail{$_->sortorder}->{speed} = $linespeeds->{'ra24'}->{speed};
            }
            else {
                $avail{$_->sortorder}->{speed} = $linespeeds->{'ra8'}->{speed};
            }
        }

        foreach my $service (@services) {
            my @s = Kirin::DB::BroadbandService->search(code => $service->{product_id});
            next if ! @s;   # Only offer services we actually sell!
            $avail{$s[0]->sortorder} = {
                name => $s[0]->name,
                id => $s[0]->id,
                crd => $self->_dates($service->{first_date}),
                price => $s[0]->price,
                speed => $service->{max_speed},
                options => $json->decode($S[0]->options),
            };
        }

        # XXX If there are to be services from other suppliers code may need
        #     to be added for it.

        # Present list of available services, activation date. XXX
        return $mm->respond('plugins/broadband/signup',
            services => \%avail, speeds => $linespeeds );

    stage_2:
        # Decode service and present T&C XXX 
        # Previous step must supply service id, crd, ip address requirement + any special options
        my $service = Kirin::DB::BroadbandService->retrieve($mm->param('id'));
        if ( ! $service ) {
            $mm->param('Please select from the available services');
            goto stage_1;
        }
        # verify that the selected crd is valid

        # Is the IP address selection OK?

        # Other options?

        # OK by this stage we have a valid order. Now onto T&C
        return $mm->respond('plugins/broadband/terms-and-conditions',
            provider => $service->provider
        );

    stage_3:
        if (!$mm->param('tc_accepted')) { # Back you go!
            $mm->param('Please accept the terms and conditions to complete your order'); 
            goto stage_2;
        }
        # XXX check that the order is valid

        # Record the order
        my $order = undef;
        my $invoice = undef;

        my $service = Kirin::DB::BroadbandService->retrieve($mm->param('id'));
        if ( $service->billed ) {
            # Calculate the price for the service (service + options)

            my $price = undef;

            $invoice = $mm->{customer}->bill_for({
                description => 'Broadband Order: '.$service->name.' on '.$mm->param('clid'),
                cost => $price
            });
        }
        $order = Kirin::DB::Orders->insert( {
            customer    => $mm->{customer},
            order_type  => 'Broadband',
            module      => __PACKAGE__,
            parameters  => $json->encode(
                service     => $service,
                customer    => $customer,
                cli         => $clid,
            ),
            invoice     => $invoice->id
        });
        if ( ! $order ) {
            Kirin::Utils->email_boss(
                severity    => "error",
                customer    => $mm->{customer},
                context     => "Trying to create order for broadband",
                message     => "Cannot create order entry for broadband ".$service->name.' on '.$mm->param('clid')
            );
            $mm->message("Our systems are unable to record your order");
            return $mm->respond("plugins/broadband/error");
        }
        $order->set_status("New Order");
        if ( $invoice ) {
            $order->set_status("Invoiced");
        }
        if ( $service->billed ) {
            return $mm->respond("plugins/invoice/view", invoice => $order->invoice);
        }
        else {
            # Process if the provider handles billing.

            # XXX Place order with provider
            $self->process($order->id);

            # XXX Create broadband db entry
            my $bb = Kirin::DB::Broadband->insert ( );
            $bb->record_event('order', 'Order Submitted');

            $order->set_status('Submitted');
            return $mm->respond("plugins/broadband/submitted");
        }
}

sub process {
    my ($self, $id) = @_;
    my $order = Kirin::DB::Orders->retrieve($id);
    if ( ! $order || ( $order->invoice && ! $order->invoice->paid ) ) {
        return;
    }
    if ( $order->module ne __PACKAGE__ ) { return; }
    
    my $op = $json->decode($order->parameters);

    my $handle = Kirin::DB::Broadband->provider_handle($op->service->provider);
    # XXX Verify the order details are valid

    # XXX place the order
    my $orderid = undef;
    my $serviceid = undef;
    if ( ! ($orderid, $serviceid) = $handle->order( # XXX ) ) {
        # XXX handle the error
    }

}

sub request_mac {
    my ($self, $mm, $id) = @_;
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
    my $bb = $self->_get_service($mm, $id);
    if ( ! $bb ) { $self->list($mm); return; }

    if (!$mm->param('date')) {
        $mm->message('Please choose a date for cancellation');
        return $mm->respond('plugins/broadband/cancel', 
            dates => $self->_dates
        )
    }

    if ( ! $mm->param('confirm') ) {
    return $mm->respond('plugins/broadband/confirm-cancel');
    }
    
    my $out = eval {
        $bb->provider_handle->cease('service-id' => $bb->token,
            reason => 'This service is no longer required',
            crd    => $mm->param('date')
        ); 
    };
    if ($@) { 
        $mm->message("An error occurred and your request could not be completed: $@");
        return $self->view($mm, $id);
    }
    $bb->status('live-ceasing');
    $bb->record_event('cease', 'Cease order placed');

    $mm->message('Cease request sent to DSL provider');
    $self->view($mm, $id);
}

sub interleaving {
    my ($self, $mm, $id) = @_;
    my $bb = $self->_get_service($mm, $id);
    if ( ! $bb ) { $self->list($mm); return; }

    # Not all providers enable interleaving changes
    if ( ! $bb->provider_handle->can('interleaving') ) {
        $mm->message('It is not possible to change interleaving on this service');
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
    my $bb = $self->_get_service($mm, $id);
    if ( ! $bb ) { $self->list($mm); return; }

}

sub usagehistory {
    my ($self, $mm, $id) = @_;
    my $bb = $self->_get_service($mm, $id);
    if ( ! $bb ) { $self->list($mm); return; }

}

sub events {
    my ($self, $mm, $id) = @_;
    my $bb = $self->_get_service($mm, $id);
    if ( ! $bb ) { $self->list($mm); return; }

    my @events = Kirin::DB::BroadbandEvent->search(broadband => $id);
    $mm->respond('plugins/broadband/events', events => \@events);    
}

sub _get_service {
    my ( $self, $mm, $id ) = @_;

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
        for (qw/name code provider price sortorder/) {
            if ( ! $mm->param($_) ) {
                $mm->message("You must specify the $_ parameter");
            }
            $mm->respond('plugins/broadband/admin');
        }
        # XXX How to handle service options ?
        # things like interleaving, enhanced care, elevated best efforts
        # ip addresses, linespeed, etc

        my $new = Kirin::DB::BroadbandService->insert({
            map { $_ => $mm->param($_) } qw/name code provider price sortorder/ 
        });
        $mm->message('Broadband Service Added');
    }
    elsif ($id = $mm->param('editproduct')) {
        my $product = Kirin::DB::BroadbandService->retrieve($id);
        if ( $product ) {
            for (qw/name code provider price sortorder/) {
                $product->$_($mm->param($_));
            }
            # XXX options bit needs to be added
            $product->update();
        }
        $mm->message('Broadband Service Updated');
    }
    elsif ($id = $mm->param('deleteproduct')) {
        my $product = Kirin::DB::BroadbandService->retrieve($id);
        if ( $product ) { $product->delete(); $mm->message('Broadband Service Deleted'); }
    }
    my @products = Kirin::DB::BroadbandService->retrieve_all();
    $mm->respond('plugins/broadband/admin', products => \@products);
}

sub _setup_db {
    Kirin->args->{$_}
        || die "You need to configure $_ in your Kirin configuration"
        for qw/murphx_username murphx_password murphx_clientid/;
    use Net::DSLProvider::Murphx; # XXX
    $murphx = Net::DSLProvider::Murphx->new({
        user => Kirin->args->{murphx_username},
        pass => Kirin->args->{murphx_password},
        clientid => Kirin->args->{murphx_clientid}
    });

    shift->_ensure_table('broadband');
    Kirin::DB::Broadband->has_a(customer => "Kirin::DB::Customer");
    Kirin::DB::Broadband->has_a(service => "Kirin::DB::BroadbandService");
    Kirin::DB::Customer->has_many(broadband => "Kirin::DB::Broadband");
    Kirin::DB::Customer->has_many(bb_search => "Kirin::DB::BroadbandSearches");
    Kirin::DB::BroadbandEvent->has_a(broadband => "Kirin::DB::Broadband");
    Kirin::DB::Broadband->has_many(events => "Kirin::DB::BroadbandEvent");
    Kirin::DB::BroadbandUsage->has_a(broadband => "Kirin::DB::Broadband");
    Kirin::DB::Broadband->has_many(usage_reports => "Kirin::DB::BroadbandUsage");
    Kirin::DB::BroadbandEvent->has_a(event_date => 'Time::Piece',
      inflate => sub { Time::Piece->strptime(shift, "%Y-%m-%d") },
      deflate => 'ymd',
    );
}

sub _dates {
    my $self = shift;
    my $first_date = shift;
    my $start = Time::Piece->new() + ONE_WEEK;
    if ( $first_date ) {
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

package Kirin::DB::Broadband;

sub provider_handle {
    my $self = shift;
    my $p = shift || $self->service->provider;
    my $module = "Net::DSLProvider::".ucfirst($p);
    $module->require or die "Can't find a provider module for $p:$@";

    $module->new({ 
        user     => Kirin->args->{"${p}_username"},
        pass     => Kirin->args->{"${p}_password"},
        clientid => Kirin->args->{"${p}_clientid"},
        debug       => 1,   # XXX
    });
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
    my %summary = $self->provider_handle->usage_summary(
        "service-id" => $self->token,
        year => $year,
        month => $mon
    );
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
    options text,
    billed integer,
);

CREATE TABLE IF NOT EXISTS broadband_options (
    id integer primary key not null,
    service integer,
    option varchar(255),
    price decimal(5,2),
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
