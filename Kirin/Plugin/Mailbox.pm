package Kirin::Plugin::Mailbox;
use strict;
use base 'Kirin::Plugin';
sub exposed_to     { 0 }
sub user_name      { "POP Mailboxes" }
sub default_action { "list" }
my $ourprimary = Kirin->args->{mx_server}
    or die "You need to set mx_server in the Kirin configuration";

Kirin::Plugin::Mailbox->relates_to("Kirin::Plugin::Domain");

sub list {
    my ($self, $mm, $domain) = @_;
    my $r;
    ($domain, $r) = Kirin::DB::Domain->web_retrieve($mm, $domain);
    return $r if $r;

    my ($local, $whohosts) = $self->_is_hosted_by($domain->domainname => "MX", $ourprimary);
    if ($mm->param("editing") and my $record = $self->_validate($domain, $mm, $local)) {
        my $action;
        if ($mm->param("deleting")) {
            $record->{db_entry}->delete(); $action = "delete";
        } elsif (my $db_entry = delete $record->{db_entry}) {
            $db_entry->$_($record->{$_}) for keys %$record;
            $db_entry->update(); $action = "update";
        } else {
            $record->{domain} = $domain->id;
            Kirin::DB::Mailbox->create($record); $action = "create";
        }
        $self->_add_todo($mm, 
            $action => join ":", $domain->domainname, 
                                 $record->{name}, $record->{password}
        );

        $mm->message("Your mailbox has been ${action}d and will be updated on the server shortly");
    }
    my @mailboxes = $local ? $domain->mailboxes: ();
    $mm->respond("plugins/mailbox/list", mailboxes=> \@mailboxes, domain => $domain,
        locally_hosted => $local, whohosts => $whohosts,
    );
}

sub _validate {
    my ($self, $domain, $mm, $local) = @_;
    my $domainname = $domain->domainname;
    if (!$local) {
        $mm->message("We don't host mail for this domain!"); return;
    }
    my $name = $mm->param("name");
    if (!$name) { return }
    my $pass = $mm->param("pass1");
    if (!$mm->param("deleting")) {
        if (!$pass) { $mm->message("You must supply a password"); return }
        if ($pass ne $mm->param("pass2")) {
            $mm->message("Passwords don't match"); return;
        }
        return unless $self->_validate_password($mm, $pass, $name, $domainname);
    }
    my $id = $mm->param("id");
    my $r;
    if ($id and $r = Kirin::DB::Mailbox->retrieve($id)
        and $r->domain != $domain) {
        # Probably a filthy hacker but we can't call them that just in case
        $mm->message("That's not your mailbox."); return;
    }
    return { name => $name, password => $pass, db_entry => $r }
}

sub _setup_db {
    shift->_ensure_table("mailbox");
    Kirin::DB::Mailbox->has_a(domain => "Kirin::DB::Domain");
    Kirin::DB::Domain->has_many(mailboxes => "Kirin::DB::Mailbox");
}

package Kirin::DB::Mailbox;

sub sql { q/
CREATE TABLE IF NOT EXISTS mailbox (
    id integer primary key not null,
    domain integer,
    name varchar(255),
    password varchar(255)
);
/ }

1;

