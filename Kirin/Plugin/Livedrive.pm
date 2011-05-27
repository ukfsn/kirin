package Kirin::Plugin::Livedrive;
use List::Util qw/sum/;
use Time::Piece;
use strict;
use base 'Kirin::Plugin';
sub user_name {"Livedrive"}

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
            message     => "Cannot cancel Livedrive service id " . $id;
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
