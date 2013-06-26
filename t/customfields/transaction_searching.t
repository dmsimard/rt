use strict;
use warnings;

use RT::Test tests => 'no_declare';

my $initialdata = RT::Test::get_relocatable_file("transaction-cfs" => "..", "data", "initialdata");
my ($rv, $msg) = RT->DatabaseHandle->InsertData( $initialdata, undef, disconnect_after => 0 );
ok($rv, "Inserted test data from $initialdata")
    or diag "Error: $msg";

my %ticket = (
    Spam        => {  },
    Coffee      => { Billable   => "No", },
    Phone       => { Billable   => "Yes", Who => ["Telecom", "Information Technology"], When => "2013-06-25", Location => "Geology" },
    Stacks      => { Billable   => "Yes", Who => "Library", When => "2013-06-01" },
    Benches     => { Billable   => "Yes", Location => "Outdoors" },
);

create_tickets();

# Sanity check
results_are("CF.Location IS NOT NULL", [qw( Phone Benches )]);
results_are("CF.Location IS NULL",     [qw( Spam Coffee Stacks )]);

# TODO: Ideal behaviour of TxnCF IS NULL not yet determined
#results_are("TxnCF.Billable IS NULL", [qw( Spam )]);

results_are("TxnCF.Billable IS NOT NULL", [qw( Coffee Phone Stacks Benches )]);
results_are("TxnCF.Billable = 'No'", [qw( Coffee )]);
results_are("TxnCF.Billable = 'Yes'", [qw( Phone Stacks Benches )]);
results_are("TxnCF.Billable = 'Yes' AND CF.Location IS NOT NULL", [qw( Phone Benches )]);
results_are("TxnCF.Billable = 'Yes' AND CF.Location = 'Outdoors'", [qw( Benches )]);
results_are("TxnCF.Billable = 'Yes' AND CF.Location LIKE 'o'", [qw( Phone Benches )]);

results_are("TxnCF.Who = 'Telecom' OR TxnCF.Who = 'Library'", [qw( Phone Stacks )]);

# TODO: Negative searching finds tickets with at least one txn doesn't have the value
#results_are("TxnCF.Who != 'Library'", [qw( Spam Coffee Phone Benches )]);

results_are("TxnCF.When > '2013-06-24'", [qw( Phone )]);
results_are("TxnCF.When < '2013-06-24'", [qw( Stacks )]);
results_are("TxnCF.When >= '2013-06-01' and TxnCF.When <= '2013-06-30'", [qw( Phone Stacks )]);

results_are("TxnCF.Who LIKE 'e'", [qw( Phone )]);

# TODO: Negative searching finds tickets with at least one txn doesn't have the value
#results_are("TxnCF.Who NOT LIKE 'e'", [qw( Spam Coffee Stacks Benches )]);

results_are("TxnCF.Who NOT LIKE 'e' and TxnCF.Who IS NOT NULL", [qw( Stacks )]);

# XXX TODO:
# Queue-specific txn CFs
# Multiple transaction CFs by name

done_testing;

sub results_are {
    local $Test::Builder::Level = $Test::Builder::Level + 1;

    my $query    = shift;
    my $expected = shift;
    my %expected = map { $_ => 1 } @$expected;
    my @unexpected;

    my $tickets = RT::Tickets->new(RT->SystemUser);
    my ($ok, $msg) = $tickets->FromSQL($query);
    ok($ok, "Searched: $query")
        or return diag $msg;
    for my $t (@{$tickets->ItemsArrayRef}) {
        if (delete $expected{$t->Subject}) {
            ok(1, "Found expected ticket ".$t->Subject);
        } else {
            push @unexpected, $t->Subject;
        }
    }
    ok(0, "Didn't find expected ticket $_")
        for grep $expected{$_}, @$expected;
    ok(0, "Found unexpected tickets: ".join ", ", @unexpected)
        if @unexpected;
}

sub create_tickets {
    for my $subject (sort keys %ticket) {
        my %cfs = %{$ticket{$subject}};
        my $location = delete $cfs{Location};

        my $ticket = RT::Ticket->new( RT->SystemUser );
        my ($ok, $msg) = $ticket->Create(
            Queue   => "General",
            Subject => $subject,
        );
        ok($ticket->id, "Created ticket: $msg") or next;

        if ($location) {
            ($ok, $msg) = $ticket->AddCustomFieldValue( Field => "Location", Value => $location );
            ok($ok, "Added Location: $msg") or next;
        }

        my ($txnid, $txnmsg, $txn) = $ticket->Correspond( Content => "test transaction" );
        unless ($txnid) {
            RT->Logger->error("Unable to correspond on ticket $ok: $txnmsg");
            next;
        }
        for my $name (sort keys %cfs) {
            my $values = ref $cfs{$name} ? $cfs{$name} : [$cfs{$name}];
            for my $v (@$values) {
                ($ok, $msg) = $txn->_AddCustomFieldValue(
                    Field => $name,
                    Value => $v,
                    RecordTransaction => 0
                );
                RT->Logger->error("Unable to add value '$v' to CF '$name': $msg")
                    unless $ok;
            }
        }
    }
}
