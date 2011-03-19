package Kirin::Plugin::Sslserver;
use strict;
use base 'Kirin::Plugin';
sub exposed_to     { 0 }
sub name { "sslserver" }
sub user_name      { "SSL Server" }
sub default_action { "edit" }

Kirin::Plugin::Sslserver->relates_to("Kirin::Plugin::Domain");

sub edit {
    my ($self, $mm, $domain) = @_;
    my $r;
    ($domain, $r) = Kirin::DB::Domain->web_retrieve($mm, $domain);
    return $r if $r;

    # Do we have one?
    my ($rec) = Kirin::DB::SslServer->search(domain => $domain);
    if ($mm->param("editing") and $mm->param("on")) {
        if ($rec) {
        } elsif ($self->_can_add_more($mm->{customer})) {
            $rec = Kirin::DB::SslServer->create({ 
                domain => $domain, customer => $mm->{customer}, 
            });
            $self->_add_todo($mm, configure_server => $domain->domainname);
            $mm->message("Your SSL hosting order has been received and will be configured shortly.");
        } else { 
            $mm->no_more("SSL servers");
        }
    } elsif ($mm->param("editing")) { # Turn it off
        if ($rec) { 
            $rec->delete;
            $self->_add_todo($mm, deconfigure_server => $domain);
            undef $rec;
        }
    }

    $mm->respond("plugins/sslserver/edit", domain => $domain,
        have_already => $rec
    );
}

sub _setup_db {
    shift->_ensure_table("ssl_server");
    Kirin::DB::SslServer->has_a(domain => "Kirin::DB::Domain");
    Kirin::DB::SslServer->has_a(customer => "Kirin::DB::Customer");
    Kirin::DB::Customer->has_many(sslservers => "Kirin::DB::SslServer");
}

package Kirin::DB::SslServer;

sub sql { q/
CREATE TABLE IF NOT EXISTS ssl_server (
    id integer primary key not null,
    customer integer,
    domain integer
);
/ }

1;

