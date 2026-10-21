package Core::Ticket;

use v5.14;
use utf8;
use parent 'Core::Base';
use Core::Base;
use Core::Utils qw( decode_json encode_json now );
use MIME::Base64 qw( decode_base64 );

sub table { return 'tickets' }

sub structure {
    return {
        ticket_id => { type => 'number', key => 1 },
        user_id => { type => 'number', auto_fill => 1, key_mul => 1 },
        subject => { type => 'text' },
        status => { type => 'text' },
        priority => { type => 'text' },
        ticket_type => { type => 'text' },
        user_service_id => { type => 'number', default => undef },
        created => { type => 'text' },
        updated => { type => 'text' },
        closed_at => { type => 'text', default => undef },
        telegram_chat_id => { type => 'text', hide_for_user => 1 },
        telegram_thread_id => { type => 'number', hide_for_user => 1 },
        telegram_error => { type => 'text', hide_for_user => 1 },
    };
}

sub _user {
    my $self = shift;
    my $user = $self->user->authenticated;
    unless ( $user && $user->id ) {
        report->status(401);
        report->add_error('Authentication required');
        return undef;
    }
    return $user;
}

sub _ticket_config {
    my $self = shift;
    my $config = { %{ cfg('ticket') || {} } };

    # Environment values are intended for Docker deployment. Database config
    # remains supported, so existing SHM installations keep working.
    $config->{id} = $ENV{TICKET_TELEGRAM_CHAT_ID}
        unless defined $config->{id} && length $config->{id};
    $config->{telegram_profile} = $ENV{TICKET_TELEGRAM_PROFILE}
        unless defined $config->{telegram_profile} && length $config->{telegram_profile};
    $config->{token} = $ENV{TICKET_TELEGRAM_BOT_TOKEN}
        unless defined $config->{token} && length $config->{token};
    return $config;
}

sub _telegram_error {
    my ( $self, $response ) = @_;
    return $self->{ticket_telegram_error} if $self->{ticket_telegram_error};
    return 'Telegram API did not return a response' unless $response;
    return $response->{description} || 'Telegram API request failed' if ref $response eq 'HASH';
    return 'Telegram API request failed' unless eval { $response->can('decoded_content') };
    my $payload = decode_json( $response->decoded_content ) || {};
    return $payload->{description} || $response->status_line || 'Telegram API request failed';
}

sub _telegram {
    my $self = shift;
    delete $self->{ticket_telegram_error};
    my $config = $self->_ticket_config;
    unless (defined $config->{id} && $config->{id} =~ /^-?\d+$/) {
        $self->{ticket_telegram_error} = 'Ticket Telegram chat ID is not configured';
        return undef;
    }

    my $tg = get_service('Transport::Telegram');
    unless ($tg) {
        $self->{ticket_telegram_error} = 'Telegram transport is unavailable';
        return undef;
    }
    $tg->profile( $config->{telegram_profile} || 'telegram_bot' );
    $tg->{token} = $config->{token} if $config->{token};
    $tg->{chat_id} = $config->{id};
    unless ($tg->token) {
        $self->{ticket_telegram_error} = 'Telegram bot token is not configured';
        return undef;
    }
    return $tg;
}

sub _telegram_result {
    my ( $self, $response ) = @_;
    return undef unless $response;
    return $response->{result} if ref $response eq 'HASH' && exists $response->{result};
    return undef unless eval { $response->can('decoded_content') };
    my $payload = decode_json( $response->decoded_content ) || {};
    return $payload->{ok} ? $payload->{result} : undef;
}

sub _is_valid_choice {
    my ( $self, $value, $allowed, $default ) = @_;
    return $default unless defined $value;
    return $allowed->{$value} ? $value : $default;
}

sub _ticket_user_label {
    my ( $self, $user ) = @_;
    my $data = $user->get || {};
    my $label = $data->{full_name} // '';
    $label =~ s/^\s+|\s+$//g;
    return $label if length $label;

    $label = $data->{login} // $user->auth_login // '';
    $label =~ s/^\s+|\s+$//g;
    return $label if length $label;
    return 'Пользователь ' . ($user->id // '');
}
sub _tg_html {
    my ( $self, $text ) = @_;
    $text //= '';
    $text =~ s/&/&amp;/g;
    $text =~ s/</&lt;/g;
    $text =~ s/>/&gt;/g;
    return $text;
}
sub _message_data {
    my ( $self, $ticket_id ) = @_;
    my $messages = $self->query(
        'SELECT message_id, ticket_id, user_id, is_admin, message, created FROM ticket_messages WHERE ticket_id=? ORDER BY message_id ASC',
        $ticket_id,
    );
    for my $message ( @{ $messages || [] } ) {
        my $media = $self->query(
            'SELECT m.id, m.name, m.mime_type, m.size, m.created FROM ticket_message_media mm JOIN ticket_media m ON m.id=mm.media_id WHERE mm.message_id=? ORDER BY m.id ASC',
            $message->{message_id},
        );
        $message->{media} = $media || [];
    }
    return $messages || [];
}

sub _ticket_data {
    my ( $self, $ticket ) = @_;
    return undef unless $ticket;
    my %data = %$ticket;
    $data{messages} = $self->_message_data( $data{ticket_id} );
    return \%data;
}

sub api_list {
    my $self = shift;
    my %args = @_;
    my $user = $self->_user || return ();
    my $limit = int($args{limit} || 100);
    $limit = 100 if $limit < 1 || $limit > 100;

    my @bind = ($user->id);
    my $where = 'WHERE user_id=?';
    if ( $args{status} && $args{status} =~ /^(?:open|in_progress|waiting|closed|archived)$/ ) {
        $where .= ' AND status=?';
        push @bind, $args{status};
    }
    my $tickets = $self->query("SELECT * FROM tickets $where ORDER BY updated DESC, ticket_id DESC LIMIT $limit", @bind);
    return map { $self->_ticket_data($_) } @{ $tickets || [] };
}

sub api_get {
    my $self = shift;
    my %args = @_;
    my $user = $self->_user || return ();
    my ($ticket) = $self->query('SELECT * FROM tickets WHERE ticket_id=? AND user_id=? LIMIT 1', $args{ticket_id}, $user->id);
    unless ($ticket) {
        report->status(404);
        report->add_error('Ticket not found');
        return ();
    }
    return ($self->_ticket_data($ticket));
}

sub _add_message {
    my ( $self, %args ) = @_;
    my $id = $self->_add(
        table => 'ticket_messages',
        ticket_id => $args{ticket_id},
        user_id => $args{user_id},
        is_admin => $args{is_admin} ? 1 : 0,
        message => $args{message},
    );
    for my $media_id ( @{ $args{media_ids} || [] } ) {
        $self->_add(table => 'ticket_message_media', message_id => $id, media_id => $media_id);
    }
    return $id;
}

sub _send_to_telegram {
    my ( $self, $ticket, $text, $media_ids ) = @_;
    my $tg = $self->_telegram || return 0;
    my %data = ( text => $text, message_thread_id => $ticket->{telegram_thread_id} );
    my $response = $tg->sendMessage(%data);
    my $sent = $self->_telegram_result($response);
    $self->{ticket_telegram_error} = $self->_telegram_error($response) unless $sent;

    for my $media_id ( @{ $media_ids || [] } ) {
        my ($media) = $self->query('SELECT name, mime_type, data FROM ticket_media WHERE id=?', $media_id);
        next unless $media;
        $tg->uploadDocument($media->{data}, filename => $media->{name}, message_thread_id => $ticket->{telegram_thread_id});
    }
    return $sent ? 1 : 0;
}

sub _create_topic {
    my ( $self, $ticket ) = @_;
    my $tg = $self->_telegram || return 0;
    my $response = $tg->http('createForumTopic', data => {
        name => sprintf('#%s %s', $ticket->{ticket_id}, substr($ticket->{subject}, 0, 80)),
    });
    my $result = $self->_telegram_result($response);
    unless ($result && $result->{message_thread_id}) {
        my $error = $self->_telegram_error($response);
        $self->_set(table => 'tickets', where => { ticket_id => $ticket->{ticket_id} }, telegram_error => $error);
        logger->warning('Ticket ' . $ticket->{ticket_id} . ': ' . $error);
        return 0;
    }
    my $config = $self->_ticket_config;
    $self->_set(
        table => 'tickets', where => { ticket_id => $ticket->{ticket_id} },
        telegram_chat_id => $config->{id}, telegram_thread_id => $result->{message_thread_id}, telegram_error => undef,
    );
    $ticket->{telegram_thread_id} = $result->{message_thread_id};
    return 1;
}

sub api_create {
    my $self = shift;
    my %args = @_;
    my $user = $self->_user || return undef;
    unless ($self->_telegram) {
        report->status(503);
        report->add_error($self->_telegram_error);
        return undef;
    }
    my $subject = $args{subject} // '';
    my $message = $args{message} // '';
    $subject =~ s/^\s+|\s+$//g;
    $message =~ s/^\s+|\s+$//g;
    unless (length($subject) && length($message)) {
        report->add_error('Subject and message are required');
        return undef;
    }
    my $id = $self->_add(
        user_id => $user->id, subject => substr($subject, 0, 160), status => 'open',
        priority => $self->_is_valid_choice($args{priority}, { map { $_ => 1 } qw(low normal high urgent) }, 'normal'),
        ticket_type => $self->_is_valid_choice($args{ticket_type}, { map { $_ => 1 } qw(service payment other) }, 'other'),
        ( $args{user_service_id} ? (user_service_id => $args{user_service_id}) : () ),
    );
    return undef unless $id;
    my ($ticket) = $self->query('SELECT * FROM tickets WHERE ticket_id=?', $id);
    $self->_add_message(ticket_id => $id, user_id => $user->id, message => $message);
    unless ($self->_create_topic($ticket)) {
        report->status(502);
        report->add_error($self->_telegram_error);
        return undef;
    }
    my $user_label = $self->_tg_html($self->_ticket_user_label($user));
    unless ($self->_send_to_telegram($ticket, "<b>Новое обращение #$id</b>\nПользователь: " . $user_label . "\nТип: " . $ticket->{ticket_type} . "\nПриоритет: " . $ticket->{priority} . "\n\n" . $self->_tg_html($message), [])) {
        report->status(502);
        report->add_error($self->_telegram_error);
        return undef;
    }
    ($ticket) = $self->query('SELECT * FROM tickets WHERE ticket_id=?', $id);
    return $self->_ticket_data($ticket);
}

sub api_send {
    my $self = shift;
    my %args = @_;
    my $user = $self->_user || return undef;
    my $ticket = $self->get || return undef;
    if ($ticket->{status} =~ /^(?:closed|archived)$/) {
        report->status(409);
        report->add_error('Ticket is closed');
        return undef;
    }
    my $message = $args{message} // '';
    $message =~ s/^\s+|\s+$//g;
    unless (length($message)) { report->add_error('Message is required'); return undef; }
    my @media = grep { /^\d+$/ } @{ $args{media_ids} || [] };
    if (@media) {
        my $found = $self->query('SELECT id FROM ticket_media WHERE user_id=? AND id IN (' . join(',', ('?') x @media) . ')', $user->id, @media);
        @media = map { $_->{id} } @$found;
    }
    my $message_id = $self->_add_message(ticket_id => $ticket->{ticket_id}, user_id => $user->id, message => $message, media_ids => \@media);
    $self->_set(table => 'tickets', where => {ticket_id => $ticket->{ticket_id}}, status => 'open', updated => now);
    if ($ticket->{telegram_thread_id} && !$self->_send_to_telegram($ticket, "<b>Пользователь #" . $user->id . ":</b>\n" . $self->_tg_html($message), \@media)) {
        report->status(502);
        report->add_error($self->_telegram_error);
        return undef;
    }
    my ($saved) = $self->query('SELECT message_id, ticket_id, user_id, is_admin, message, created FROM ticket_messages WHERE message_id=?', $message_id);
    $saved->{media} = $self->query('SELECT m.id, m.name, m.mime_type, m.size, m.created FROM ticket_message_media mm JOIN ticket_media m ON m.id=mm.media_id WHERE mm.message_id=?', $message_id) || [];
    return $saved;
}

sub api_close {
    my $self = shift;
    my $ticket = $self->get || return undef;
    return $ticket if $ticket->{status} eq 'closed';
    $self->_set(table => 'tickets', where => {ticket_id => $ticket->{ticket_id}}, status => 'closed', closed_at => now, updated => now);
    if ($ticket->{telegram_thread_id}) {
        my $tg = $self->_telegram;
        if ($tg) {
            my $response = $tg->http('deleteForumTopic', data => {
                message_thread_id => $ticket->{telegram_thread_id},
            });
            unless ($self->_telegram_result($response)) {
                my $error = $self->_telegram_error($response);
                $self->_set(
                    table => 'tickets',
                    where => { ticket_id => $ticket->{ticket_id} },
                    telegram_error => $error,
                );
                logger->warning('Ticket ' . $ticket->{ticket_id} . ': failed to delete Telegram topic: ' . $error);
            }
        }
    }
    my ($saved) = $self->query('SELECT * FROM tickets WHERE ticket_id=?', $ticket->{ticket_id});
    return $self->_ticket_data($saved);
}

sub api_upload_media {
    my $self = shift;
    my %args = @_;
    my $user = $self->_user || return undef;
    my $data = eval { decode_base64($args{data} // '') };
    unless (defined($data) && length($data) && length($data) <= 5 * 1024 * 1024) {
        report->add_error('Invalid attachment data'); return undef;
    }
    my $name = $args{name} // 'attachment';
    $name =~ s/[^\w.() -]+/_/g;
    my $id = $self->_add(table => 'ticket_media', user_id => $user->id, name => substr($name,0,255), mime_type => substr($args{mime_type} // 'application/octet-stream',0,100), size => length($data), data => $data);
    my ($media) = $self->query('SELECT id, name, mime_type, size, created FROM ticket_media WHERE id=?', $id);
    return $media;
}

sub api_download_media {
    my $self = shift;
    my %args = @_;
    my $user = $self->_user || return '';
    my ($media) = $self->query('SELECT data FROM ticket_media WHERE id=? AND user_id=?', $args{id}, $user->id);
    unless ($media) { report->status(404); report->add_error('Attachment not found'); return ''; }
    return $media->{data};
}

sub process_telegram_message {
    my $self = shift;
    my %args = @_;
    my $message = $args{message} || {};
    my $config = $self->_ticket_config || return 0;
    my $chat_id = $message->{chat}->{id};
    return 0 unless defined $chat_id && "$chat_id" eq "$config->{id}";

    my $thread_id = $message->{message_thread_id};
    return 0 unless $thread_id;
    return 1 if $message->{from}->{is_bot};

    # Anonymous administrators are represented by sender_chat rather than from.
    my $sender_id = $message->{from}->{id};
    my $anonymous_admin = defined $message->{sender_chat}->{id}
        && "$message->{sender_chat}->{id}" eq "$config->{id}";
    return 0 unless $sender_id || $anonymous_admin;

    my ($ticket) = $self->query(
        'SELECT * FROM tickets WHERE telegram_chat_id=? AND telegram_thread_id=? LIMIT 1',
        $config->{id}, $thread_id,
    );
    unless ($ticket) {
        logger->debug("Ticket Telegram reply ignored: topic $thread_id is not linked to a ticket");
        return 0;
    }
    return 1 if $ticket->{status} =~ /^(?:closed|archived)$/;

    unless ($anonymous_admin) {
        # The webhook transport already has the verified bot token and chat ID.
        my $tg = $args{telegram} || $self->_telegram;
        unless ($tg) {
            logger->warning('Ticket ' . $ticket->{ticket_id} . ': Telegram transport is unavailable for an incoming reply');
            return 1;
        }
        my $member = $self->_telegram_result(
            $tg->http('getChatMember', data => { user_id => $sender_id })
        );
        unless ($member && ($member->{status} // '') =~ /^(?:administrator|creator|owner)$/) {
            logger->warning('Ticket ' . $ticket->{ticket_id} . ': Telegram reply ignored because sender is not a group administrator');
            return 1;
        }
    }

    my $text = $message->{text} // $message->{caption} // '';
    return 1 unless length $text;
    $self->_add_message(ticket_id => $ticket->{ticket_id}, user_id => 0, is_admin => 1, message => $text);
    $self->_set(table => 'tickets', where => {ticket_id => $ticket->{ticket_id}}, status => 'waiting', updated => now);
    logger->info('Ticket ' . $ticket->{ticket_id} . ': Telegram support reply saved');
    return 1;
}

1;



