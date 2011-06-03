#!/usr/bin/perl -w
#
# FixMyStreet::Alert.pm
# Alerts by email or RSS.
#
# Copyright (c) 2007 UK Citizens Online Democracy. All rights reserved.
# Email: matthew@mysociety.org; WWW: http://www.mysociety.org/
#
# $Id: Alert.pm,v 1.71 2010-01-06 16:50:27 louise Exp $

package FixMyStreet::Alert;

use strict;
use Error qw(:try);
use File::Slurp;
use FindBin;
use POSIX qw(strftime);

use Cobrand;
use mySociety::AuthToken;
use mySociety::DBHandle qw(dbh);
use mySociety::Email;
use mySociety::EmailUtil;
use mySociety::Gaze;
use mySociety::Locale;
use mySociety::MaPit;
use mySociety::Random qw(random_bytes);

# Child must have confirmed, id, email, state(!) columns
# If parent/child, child table must also have name and text
#   and foreign key to parent must be PARENT_id
sub email_alerts ($) {
    my ($testing_email) = @_;
    my $url; 
    my $q = dbh()->prepare("select * from alert_type where ref not like '%local_problems%'");
    $q->execute();
    my $testing_email_clause = '';
    while (my $alert_type = $q->fetchrow_hashref) {
        my $ref = $alert_type->{ref};
        my $head_table = $alert_type->{head_table};
        my $item_table = $alert_type->{item_table};
        my $testing_email_clause = "and $item_table.email <> '$testing_email'" if $testing_email;
        my $query = 'select alert.id as alert_id, alert.email as alert_email, alert.lang as alert_lang, alert.cobrand as alert_cobrand,
            alert.cobrand_data as alert_cobrand_data, alert.parameter as alert_parameter, alert.parameter2 as alert_parameter2, ';
        if ($head_table) {
            $query .= "
                   $item_table.id as item_id, $item_table.name as item_name, $item_table.text as item_text,
                   $head_table.*
            from alert
                inner join $item_table on alert.parameter::integer = $item_table.${head_table}_id
                inner join $head_table on alert.parameter::integer = $head_table.id";
        } else {
            $query .= " $item_table.*,
                   $item_table.id as item_id
            from alert, $item_table";
        }
        $query .= "
            where alert_type='$ref' and whendisabled is null and $item_table.confirmed >= whensubscribed
            and $item_table.confirmed >= ms_current_timestamp() - '7 days'::interval
             and (select whenqueued from alert_sent where alert_sent.alert_id = alert.id and alert_sent.parameter::integer = $item_table.id) is null
            and $item_table.email <> alert.email 
            $testing_email_clause
            and $alert_type->{item_where}
            and alert.confirmed = 1
            order by alert.id, $item_table.confirmed";
        # XXX Ugh - needs work
        $query =~ s/\?/alert.parameter/ if ($query =~ /\?/);
        $query =~ s/\?/alert.parameter2/ if ($query =~ /\?/);
        $query = dbh()->prepare($query);
        $query->execute();
        my $last_alert_id;
        my %data = ( template => $alert_type->{template}, data => '' );
        while (my $row = $query->fetchrow_hashref) {
            # Cobranded and non-cobranded messages can share a database. In this case, the conf file 
            # should specify a vhost to send the reports for each cobrand, so that they don't get sent 
            # more than once if there are multiple vhosts running off the same database. The email_host
            # call checks if this is the host that sends mail for this cobrand.
            next unless (Cobrand::email_host($row->{alert_cobrand}));

            dbh()->do('insert into alert_sent (alert_id, parameter) values (?,?)', {}, $row->{alert_id}, $row->{item_id});
            if ($last_alert_id && $last_alert_id != $row->{alert_id}) {
                _send_aggregated_alert_email(%data);
                %data = ( template => $alert_type->{template}, data => '' );
            }

            # create problem status message for the templates
            $data{state_message} =
              $row->{state} eq 'fixed'
              ? _("This report is currently marked as fixed.")
              : _("This report is currently marked as open.");

            $url = Cobrand::base_url_for_emails($row->{alert_cobrand}, $row->{alert_cobrand_data});
            if ($row->{item_text}) {
                $data{problem_url} = $url . "/report/" . $row->{id};
                $data{data} .= $row->{item_name} . ' : ' if $row->{item_name};
                $data{data} .= $row->{item_text} . "\n\n------\n\n";
            } else {
                $data{data} .= $url . "/report/" . $row->{id} . " - $row->{title}\n\n";
            }
            if (!$data{alert_email}) {
                %data = (%data, %$row);
                if ($ref eq 'area_problems' || $ref eq 'council_problems' || $ref eq 'ward_problems') {
                    my $va_info = mySociety::MaPit::call('area', $row->{alert_parameter});
                    $data{area_name} = $va_info->{name};
                }
                if ($ref eq 'ward_problems') {
                    my $va_info = mySociety::MaPit::call('area', $row->{alert_parameter2});
                    $data{ward_name} = $va_info->{name};
                }
            }
            $data{cobrand} = $row->{alert_cobrand};
            $data{cobrand_data} = $row->{alert_cobrand_data};
            $data{lang} = $row->{alert_lang};
            $last_alert_id = $row->{alert_id};
        }
        if ($last_alert_id) {
            _send_aggregated_alert_email(%data);
        }
    }

    # Nearby done separately as the table contains the parameters
    my $template = dbh()->selectrow_array("select template from alert_type where ref = 'local_problems'");
    my $query = "select * from alert where alert_type='local_problems' and whendisabled is null and confirmed=1 order by id";
    $query = dbh()->prepare($query);
    $query->execute();
    while (my $alert = $query->fetchrow_hashref) {
        next unless (Cobrand::email_host($alert->{cobrand}));
        my $longitude = $alert->{parameter};
        my $latitude  = $alert->{parameter2};
        $url = Cobrand::base_url_for_emails($alert->{cobrand}, $alert->{cobrand_data});
        my ($site_restriction, $site_id) = Cobrand::site_restriction($alert->{cobrand}, $alert->{cobrand_data});
        my $d = mySociety::Gaze::get_radius_containing_population($latitude, $longitude, 200000);
        # Convert integer to GB locale string (with a ".")
        $d = mySociety::Locale::in_gb_locale {
            sprintf("%f", int($d*10+0.5)/10);
        };
        my $testing_email_clause = "and problem.email <> '$testing_email'" if $testing_email;        
        my %data = ( template => $template, data => '', alert_id => $alert->{id}, alert_email => $alert->{email}, lang => $alert->{lang}, cobrand => $alert->{cobrand}, cobrand_data => $alert->{cobrand_data} );
        my $q = "select * from problem_find_nearby(?, ?, ?) as nearby, problem
            where nearby.problem_id = problem.id and problem.state in ('confirmed', 'fixed')
            and problem.confirmed >= ? and problem.confirmed >= ms_current_timestamp() - '7 days'::interval
            and (select whenqueued from alert_sent where alert_sent.alert_id = ? and alert_sent.parameter::integer = problem.id) is null
            and problem.email <> ?
            $testing_email_clause
            $site_restriction
            order by confirmed desc";
        $q = dbh()->prepare($q);
        $q->execute($latitude, $longitude, $d, $alert->{whensubscribed}, $alert->{id}, $alert->{email});
        while (my $row = $q->fetchrow_hashref) {
            dbh()->do('insert into alert_sent (alert_id, parameter) values (?,?)', {}, $alert->{id}, $row->{id});
            $data{data} .= $url . "/report/" . $row->{id} . " - $row->{title}\n\n";
        }
        _send_aggregated_alert_email(%data) if $data{data};
    }
}

sub _send_aggregated_alert_email(%) {
    my %data = @_;
    Cobrand::set_lang_and_domain($data{cobrand}, $data{lang}, 1);

    $data{unsubscribe_url} = Cobrand::base_url_for_emails($data{cobrand}, $data{cobrand_data}) . '/A/'
        . mySociety::AuthToken::store('alert', { id => $data{alert_id}, type => 'unsubscribe', email => $data{alert_email} } );
    my $template = "$FindBin::Bin/../templates/emails/$data{template}";
    if ($data{cobrand}) {
        my $template_cobrand = "$FindBin::Bin/../templates/emails/$data{cobrand}/$data{template}";
        $template = $template_cobrand if -e $template_cobrand;
    }
    $template = File::Slurp::read_file($template);
    my $sender = Cobrand::contact_email($data{cobrand});
    my $sender_name = Cobrand::contact_name($data{cobrand});
    (my $from = $sender) =~ s/team/fms-DO-NOT-REPLY/; # XXX
    my $email = mySociety::Email::construct_email({
        _template_ => _($template),
        _parameters_ => \%data,
        From => [ $from, _($sender_name) ],
        To => $data{alert_email},
        'Message-ID' => sprintf('<alert-%s-%s@mysociety.org>', time(), unpack('h*', random_bytes(5, 1))),
    });

    my $result = mySociety::EmailUtil::send_email($email, $sender, $data{alert_email});
    if ($result == mySociety::EmailUtil::EMAIL_SUCCESS) {
        dbh()->commit();
    } else {
        dbh()->rollback();
        print "Failed to send alert $data{alert_id}!";
    }
}

1;
