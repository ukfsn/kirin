package Kirin::Plugin::Livedrive;
use List::Util qw/sum/;
use Time::Piece;
use JSON;
use strict;
use base 'Kirin::Plugin';
sub user_name {"Livedrive"}
sub default_action { "list" }

my $json = JSON->new->allow_blessed;

sub list {
    my ($self, $mm) = @_;
    my @livedrives = Kirin::DB::Livedrive->search(customer => $mm->{customer});
    $mm->respond("plugins/livedrive/list", services => \@livedrives);
}

sub view {
    my ($self, $mm, $id) = @_;
    my $service = Kirin::DB::Livedrive->retrieve($id);
    if ( ! $service ) {
        $self->list("Cannot find service");
    }
    $mm->respond("plugins/livedrive/view", service => $service);
}

sub cancel {
    my ($self, $mm, $id) = @_;
    my $service = Kirin::DB::Livedrive->retrieve($id);

    if ( ! $service ) {
        $mm->message("Cannot find service to cancel");
        return $self->list();
    }

    if ( ! $service->active ) {
        $self->message("That service has already been cancelled");
        return $self->list();
    }

    if ( ! $service->close_service() ) {
        Kirin::Utils->email_boss(
            severity    => "error",
            customer    => $mm->{customer},
            context     => "Trying to cancel Livedrive service",
            message     => "Cannot cancel Livedrive service id $id"
        );
        $mm->message("An error occured cancelling your service. Please contact support.");
        return $self->list();
    }

    $service->active(0);
    $service->update();

    $mm->{customer}->log( plugin => __PACKAGE__,
        event => 'Cancel',
        details => $service->login
    );
    $mm->message("Livedrive Backup account cancelled and all backup data deleted");
    $self->list();
}

sub order {
    my ($self, $mm) = @_;

    my $invoice = $mm->{customer}->bill_for({
        description  => "Livedrive service for ",
        cost         => 0 # XXX
    });

    my $order = Kirin::DB::Orders->insert({
        customer    => $mm->{customer},
        order_type  => 'Livedrive Backup',
        module      => __PACKAGE__,
        parameters  => $json->encode( {
            email       => "data",
            password    => "data",
            capacity    => "data",
            product     => "data"
        }),
        invoice     => $invoice->id,
    });
    if ( ! $order ) {
        Kirin::Utils->email_boss(
            severity    => "error",
            customer    => $mm->{customer},
            context     => "Trying to register order for Livedrive",
            message     => "Cannot create order entry for Livedrive service"
        );
        $mm->message("Our systems are unable to record your order");
        return $mm->respond("plugins/livedrive/order");
    }
    $order->set_status("New Order");
    $order->set_status("Invoiced");

    return $mm->respond("plugins/invoice/view", invoice => $order->invoice);
}

sub process {
    my ($self, $id) = @_;
    my $order = Kirin::DB::Orders->retrieve($id);
    if ( ! $order || ( $order->invoice && ! $order->invoice->paid ) ) {
        return;
    }
    if ( $order->module ne __PACKAGE__ ) { return; }
    return if ( $order->status ne 'Ready' || $order->status ne 'Invoiced' );
    my $op = $json->decode($order->parameters);
    my $customer = Kirin::DB::Customer->retrieve($order->customer);

    my $handle = Kirin::DB::Livedrive->handle();
    my $ld_user = $handle->adduser(
        email => $op->email,
        password => $op->password,
        confirmPassword => $op->password,
        subDomain => $customer->user->username . '.ukfsn.org',
        capacity => $op->capacity,
        isSharing => 1,
        hasWebApps => 1,
        firstName => $customer->firstname,
        lastName => $customer->lastname,
        cardVerificationValue => Kirin->args->{livedrive_verification},
        productType => $op->product
    );
    return if ! $ld_user;
    $order->set_status('Livedrive account created');

    my $service = Kirin::DB::Livedrive->insert({
        customer => $customer->id,
        livedriveid => $ld_user->{id},
        login => $ld_user->email,
        password => $op->password,
        host => $customer->user->username . '.ukfsn.org',
        backup => 1,
        briefcase =>  
        active => 1
    });
    return if ! $service;
    $order->set_status('Completed');
    return 1;
}

sub _setup_db {
    shift->_ensure_table("livedrive");
    Kirin::DB::Livedrive->has_a(customer => "Kirin::DB::Customer");
    Kirin::DB::Customer->has_many(livedrive => "Kirin::DB::Livedrive");
}

package Kirin::DB::Livedrive;

sub handle {
    my $self = shift;

    Business::LiveDrive->require or die "Cannot find LiveDrive module";
    Business::LiveDrive->new(apiKey => Kirin->args->{livedrive_key});
}

sub getuser {
    my $self = shift;
    $self->handle->getuser($self->livedriveid);
}

sub close_service {
    my $self = shift;
    $self->handle->closeuser($self->livedriveid);
}

sub sql{q/
CREATE TABLE IF NOT EXISTS livedrive ( id integer primary key not null,
    customer integer,
    livedriveid integer,
    login varchar(40) NOT NULL,
    password varchar(40) NOT NULL, 
    host varchar(40) NOT NULL,
    backup integer,
    briefcase integer,
    active integer
);

/}
1;
