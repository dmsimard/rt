#!/usr/bin/perl
use strict;
use warnings;

use RT::Test tests => 92;

my $openssl = RT::Test->find_executable('openssl');
plan skip_all => 'openssl executable is required.'
    unless $openssl;

use Digest::MD5 qw(md5_hex);

my $mails = RT::Test::get_abs_relocatable_dir(
    (File::Spec->updir()) x 2,
    qw(data smime mails),
);
my $keyring = RT::Test->new_temp_dir(
    crypt => smime => 'smime_keyring'
);

RT->Config->Set( Crypt =>
    Enable   => 1,
    Incoming => ['SMIME'],
    Outgoing => 'SMIME',
);
RT->Config->Set( GnuPG => Enable => 0 );
RT->Config->Set( SMIME =>
    Enable => 1,
    Passphrase => {
        'root@example.com' => '123456',
    },
    OpenSSL => $openssl,
    Keyring => $keyring,
);
RT->Config->Set( 'MailPlugins' => 'Auth::MailFrom', 'Auth::Crypt' );

{
    my $cf = RT::CustomField->new( $RT::SystemUser );
    my ($ret, $msg) = $cf->Create(
        Name       => 'SMIME Key',
        LookupType => RT::User->new( $RT::SystemUser )->CustomFieldLookupType,
        Type       => 'TextSingle',
    );
    ok($ret, "Custom Field created");

    my $OCF = RT::ObjectCustomField->new( $RT::SystemUser );
    $OCF->Create(
        CustomField => $cf->id,
        ObjectId    => 0,
    );
}

RT::Test->import_smime_key('root@example.com');
RT::Test->import_smime_key('sender@example.com');

my ($baseurl, $m) = RT::Test->started_ok;
ok $m->login, 'we did log in';
$m->get_ok( '/Admin/Queues/');
$m->follow_link_ok( {text => 'General'} );
$m->submit_form( form_number => 3,
         fields      => { CorrespondAddress => 'root@example.com' } );

diag "load Everyone group" if $ENV{'TEST_VERBOSE'};
my $everyone;
{
    $everyone = RT::Group->new( $RT::SystemUser );
    $everyone->LoadSystemInternalGroup('Everyone');
    ok $everyone->id, "loaded 'everyone' group";
}

RT::Test->set_rights(
    Principal => $everyone,
    Right => ['CreateTicket'],
);


my $eid = 0;
for my $usage (qw/signed encrypted signed&encrypted/) {
    for my $attachment (qw/plain text-attachment binary-attachment/) {
        ++$eid;
        diag "Email $eid: $usage, $attachment email" if $ENV{TEST_VERBOSE};
        eval { email_ok($eid, $usage, $attachment) };
    }
}

sub email_ok {
    my ($eid, $usage, $attachment) = @_;
    diag "email_ok $eid: $usage, $attachment" if $ENV{'TEST_VERBOSE'};

    my ($file) = glob("$mails/$eid-*");
    my $mail = RT::Test->file_content($file);

    my ($status, $id) = RT::Test->send_via_mailgate($mail);
    is ($status >> 8, 0, "$eid: The mail gateway exited normally");
    ok ($id, "$eid: got id of a newly created ticket - $id");

    my $tick = RT::Ticket->new( $RT::SystemUser );
    $tick->Load( $id );
    ok ($tick->id, "$eid: loaded ticket #$id");

    is ($tick->Subject,
        "Test Email ID:$eid",
        "$eid: Created the ticket"
    );

    my $txn = $tick->Transactions->First;
    my ($msg, @attachments) = @{$txn->Attachments->ItemsArrayRef};

    is( $msg->GetHeader('X-RT-Privacy'),
        'SMIME',
        "$eid: recorded incoming mail that is secured"
    );

    if ($usage =~ /encrypted/) {
        is( $msg->GetHeader('X-RT-Incoming-Encryption'),
            'Success',
            "$eid: recorded incoming mail that is encrypted"
        );
        like( $attachments[0]->Content, qr/ID:$eid/,
                "$eid: incoming mail did NOT have original body"
        );
    }
    else {
        is( $msg->GetHeader('X-RT-Incoming-Encryption'),
            'Not encrypted',
            "$eid: recorded incoming mail that is not encrypted"
        );
        like( $msg->Content || $attachments[0]->Content, qr/ID:$eid/,
            "$eid: got original content"
        );
    }

    if ($usage =~ /signed/) {
        is( $msg->GetHeader('X-RT-Incoming-Signature'),
            '"sender" <sender@example.com>',
            "$eid: recorded incoming mail that is signed"
        );
    }
    else {
        is( $msg->GetHeader('X-RT-Incoming-Signature'),
            undef,
            "$eid: recorded incoming mail that is not signed"
        );
    }

    if ($attachment =~ /attachment/) {
        my ($a) = grep $_->Filename, @attachments;
        ok ($a && $a->Id, "$eid: found attachment with filename");

        my $acontent = $a->Content;
        if ($attachment =~ /binary/)
        {
            is(md5_hex($acontent), '1e35f1aa90c98ca2bab85c26ae3e1ba7', "$eid: The binary attachment's md5sum matches");
        }
        else
        {
            like($acontent, qr/zanzibar/, "$eid: The attachment isn't screwed up in the database.");
        }
    }

    return 0;
}

