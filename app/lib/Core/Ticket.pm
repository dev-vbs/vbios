package Core::Ticket;

use v5.14;
use utf8;
use parent 'Core::Base';
use Core::Base;
use Core::Utils qw(decode_json);
use Core::System::ServiceManager qw(get_service logger);

sub table { 'tickets' }
sub structure {
    return {
        ticket_id => { type => 'number', key => 1 }, user_id => { type => 'number' },
        subject => { type => 'text' }, status => { type => 'text' }, priority => { type => 'text' },
        ticket_type => { type => 'text' }, user_service_id => { type => 'number' }, created => { type => 'text' },
        updated => { type => 'text' }, closed_at => { type => 'text' }, telegram_chat_id => { type => 'number' },
        telegram_thread_id => { type => 'number' }, telegram_error => { type => 'text' },
    };
}

sub _row { my ($self,$id)=@_; return $self->dbh->selectrow_hashref('SELECT * FROM tickets WHERE ticket_id = ?', undef, $id) }
sub _messages {
    my ($self,$id)=@_; my $rows=$self->dbh->selectall_arrayref('SELECT * FROM ticket_messages WHERE ticket_id=? ORDER BY message_id', {Slice=>{}}, $id);
    for my $m (@$rows) { $m->{media}=$self->dbh->selectall_arrayref('SELECT m.id,m.name,m.mime_type,m.size,m.created FROM ticket_media m JOIN ticket_message_media x ON x.media_id=m.id WHERE x.message_id=? ORDER BY m.id',{Slice=>{}},$m->{message_id}) }
    return $rows;
}
sub _result { my ($self,$id,$full)=@_; my $r=$self->_row($id)||{}; $r->{messages}=$self->_messages($id) if $full; return $r }
sub _input { my ($self,%a)=@_; return (%a ? %a : %{$self->res||{}}) }

sub api_list {
    my ($self,%a)=@_; my $uid=$self->user_id; my $status=$a{status};
    my $sql='SELECT * FROM tickets WHERE user_id=?'; my @p=($uid); if (defined $status && length $status) { $sql.=' AND status=?'; push @p,$status } $sql.=' ORDER BY updated DESC LIMIT 100';
    my $rows=$self->dbh->selectall_arrayref($sql,{Slice=>{}},@p); $_->{messages}=$self->_messages($_->{ticket_id}) for @$rows; return wantarray ? @$rows : $rows;
}
sub api_get { my ($self,%a)=@_; my $id=$a{ticket_id}||$a{id}; my $row=$self->_row($id); die 'ticket not found' unless $row && $row->{user_id} == $self->user_id; return $self->_result($id,1) }
sub api_create {
    my ($self,%a)=@_; my $uid=$self->user_id; my $subject=substr(($a{subject}//'Без темы'),0,160); my $msg=substr(($a{message}//''),0,10000); die 'message is required' unless length $msg;
    if ($a{user_service_id}) {
        my ($owned) = $self->dbh->selectrow_array('SELECT 1 FROM user_services WHERE user_service_id=? AND user_id=?', undef, $a{user_service_id}, $uid);
        die 'service not found' unless $owned;
    }
    my $id=$self->add(user_id=>$uid,subject=>$subject,status=>'open',priority=>($a{priority}||'normal'),ticket_type=>($a{ticket_type}||'other'),user_service_id=>$a{user_service_id});
    $self->_add_message($id,$uid,0,$msg,$a{media_ids});
    # Telegram is an external service. Never roll back a successfully created
    # ticket when Telegram is unavailable or the forum is misconfigured.
    eval { $self->telegram_sync($id); 1 } or do {
        my $error = $@ || 'Telegram synchronization failed';
        $self->dbh->do('UPDATE tickets SET telegram_error=? WHERE ticket_id=?', undef, substr("$error", 0, 255), $id);
    };
    return $self->_result($id,1);
}
sub _add_message {
    my ($self,$tid,$uid,$admin,$msg,$media)=@_; my $mid=$self->dbh->do('INSERT INTO ticket_messages(ticket_id,user_id,is_admin,message) VALUES(?,?,?,?)',undef,$tid,$uid,$admin,$msg); $mid=$self->insert_id;
    for my $media_id (@{$media||[]}) { $self->dbh->do('INSERT IGNORE INTO ticket_message_media(message_id,media_id) SELECT ?,id FROM ticket_media WHERE id=? AND user_id=?',undef,$mid,$media_id,$uid) }
    $self->dbh->do('UPDATE tickets SET status=?,updated=NOW() WHERE ticket_id=?',undef,$admin?'waiting':'open',$tid); return $mid;
}
sub api_message { my ($self,%a)=@_; my $id=$a{ticket_id}||$a{id}; my $r=$self->_row($id); die 'ticket not found' unless $r && $r->{user_id}==$self->user_id; die 'ticket closed' if $r->{status} eq 'closed'; my $mid=$self->_add_message($id,$self->user_id,0,substr(($a{message}//''),0,10000),$a{media_ids}); eval { $self->telegram_sync($id); 1 } or $self->dbh->do('UPDATE tickets SET telegram_error=? WHERE ticket_id=?',undef,substr("$@",0,255),$id); return $self->dbh->selectrow_hashref('SELECT * FROM ticket_messages WHERE message_id=?',undef,$mid) }
sub api_close { my ($self,%a)=@_; my $id=$a{ticket_id}||$a{id}; my $r=$self->_row($id); die 'ticket not found' unless $r && $r->{user_id}==$self->user_id; $self->dbh->do("UPDATE tickets SET status='closed',closed_at=NOW(),updated=NOW() WHERE ticket_id=?",undef,$id); $self->telegram_close($id); return $self->_result($id,1) }
sub api_media { my ($self,%a)=@_; die 'file data is required' unless $a{data}; my $id=$self->dbh->do('INSERT INTO ticket_media(user_id,name,mime_type,size,data) VALUES(?,?,?,?,FROM_BASE64(?))',undef,$self->user_id,substr(($a{name}||'file'),0,255),$a{mime_type},length($a{data}),$a{data}); return $self->dbh->selectrow_hashref('SELECT id,name,mime_type,size,created FROM ticket_media WHERE id=?',undef,$self->insert_id) }
sub api_media_download { my ($self,%a)=@_; my $r=$self->dbh->selectrow_hashref('SELECT * FROM ticket_media WHERE id=? AND user_id=?',undef,$a{id},$self->user_id); return $r }

sub _tg {
    my $self = shift;
    my $tg = get_service('Transport::Telegram') or die 'Telegram transport is unavailable';
    my $cfg = get_service('config')->data_by_name('ticket') || {};
    my $name = $cfg->{telegram_profile} || 'telegram_bot';
    my $telegram = $tg->config || {};
    my $profile = $telegram->{$name};
    die "Telegram ticket profile '$name' is not configured" unless ref($profile) eq 'HASH';
    my $token = $profile->{token};
    die "Telegram ticket token is not configured for profile '$name'" unless defined $token && length $token;
    $tg->profile($name);
    # Assign the current configured value even if a cached transport was reused.
    $tg->{token} = $token;
    return $tg;
}
sub telegram_sync {
    my ($self, $id) = @_;
    my $cfg = get_service('config')->data_by_name('ticket') || {};
    my $chat = $cfg->{id} || $cfg->{admin_chat_id};
    unless ($chat) {
        $self->dbh->do('UPDATE tickets SET telegram_error=? WHERE ticket_id=?', undef, 'Telegram chat is not configured', $id);
        return;
    }
    my $r = $self->_row($id) or die 'ticket not found';
    my $m = $self->dbh->selectrow_hashref('SELECT * FROM ticket_messages WHERE ticket_id=? ORDER BY message_id DESC LIMIT 1', undef, $id) or return;
    my $tg = $self->_tg;
    my $thread = $r->{telegram_thread_id};
    $chat = $r->{telegram_chat_id} if $thread && $r->{telegram_chat_id};
    # Forum topics are opt-in. Plain chats and ordinary groups receive messages directly.
    if ($cfg->{forum_topics} && !$thread) {
        my $response = $tg->http('createForumTopic', chat_id => $chat, data => {chat_id => $chat, name => substr("#$id $r->{subject}", 0, 128)});
        my $body = eval { $response->decoded_content } || '';
        my $result = eval { decode_json($body) } || {};
        $thread = $result->{result}{message_thread_id};
        die 'Telegram topic creation failed: ' . ($result->{description} || 'no response') unless $result->{ok} && $thread;
        $self->dbh->do('UPDATE tickets SET telegram_chat_id=?,telegram_thread_id=? WHERE ticket_id=?', undef, $chat, $thread, $id);
    }
    my $u = $self->dbh->selectrow_hashref('SELECT login,full_name FROM users WHERE user_id=?', undef, $r->{user_id}) || {};
    my $display = $u->{full_name} || $u->{login} || 'Пользователь';
    $display =~ s/[\r\n]+/ /g;
    my $subject = $r->{subject} || 'Без темы';
    $subject =~ s/[\r\n]+/ /g;
    my %types = (service => 'Услуга', payment => 'Оплата', other => 'Другое');
    my %priorities = (low => 'Низкий', normal => 'Обычный', high => 'Высокий', urgent => 'Срочный');
    my $kind = $types{$r->{ticket_type} || ''} || 'Другое';
    my $priority = $priorities{$r->{priority} || ''} || 'Обычный';
    my $service_line = '';
    if ($r->{user_service_id}) {
        my $service = $self->dbh->selectrow_hashref('SELECT s.name FROM user_services us JOIN services s ON s.service_id=us.service_id WHERE us.user_service_id=? AND us.user_id=?', undef, $r->{user_service_id}, $r->{user_id});
        my $name = $service && $service->{name} ? $service->{name} : 'Название недоступно';
        $name =~ s/[\r\n]+/ /g;
        $service_line = "\n🌐 Услуга: $name (#$r->{user_service_id})";
    }
    my $heading = $m->{message_id} == ($self->dbh->selectrow_array('SELECT MIN(message_id) FROM ticket_messages WHERE ticket_id=?', undef, $id) || 0) ? 'Новое обращение' : 'Новое сообщение';
    my $text = "📩 $heading #$id\n👤 $display · ID $r->{user_id}\n📌 $subject\n📂 $kind · ⚡ $priority$service_line\n\n💬 " . $m->{message};
    $text = substr($text, 0, 4000);
    my $keyboard;
    if (defined $cfg->{admin_user_url_template} && $cfg->{admin_user_url_template} =~ m{^https://[^\s]+$} && $cfg->{admin_user_url_template} =~ /\{user_id\}/) {
        my $url = $cfg->{admin_user_url_template};
        $url =~ s/\{user_id\}/$r->{user_id}/g;
        $keyboard = { inline_keyboard => [[{ text => '👤 Открыть пользователя', url => $url }]] };
    }
    my $response = $tg->http('sendMessage', chat_id => $chat, data => {
        chat_id => $chat, ($thread ? (message_thread_id => $thread) : ()), text => $text,
        ($keyboard ? (reply_markup => $keyboard) : ()),
    });
    my $body = eval { $response->decoded_content } || '';
    my $result = eval { decode_json($body) } || {};
    die 'Telegram notification failed: ' . ($result->{description} || 'no response') unless $result->{ok};
    $self->dbh->do('UPDATE tickets SET telegram_error=NULL WHERE ticket_id=?', undef, $id);
}
sub telegram_close {
    my ($self, $id) = @_;
    my $r = $self->_row($id) or return;
    return unless $r->{telegram_chat_id} && $r->{telegram_thread_id};
    my $error;
    eval {
        my $response = $self->_tg->http('deleteForumTopic', chat_id => $r->{telegram_chat_id}, data => {
            chat_id => $r->{telegram_chat_id}, message_thread_id => $r->{telegram_thread_id},
        });
        my $body = eval { $response->decoded_content } || '';
        my $result = eval { decode_json($body) } || {};
        die 'Telegram topic deletion failed: ' . ($result->{description} || 'no response') unless $result->{ok};
        $self->dbh->do('UPDATE tickets SET telegram_error=NULL WHERE ticket_id=?', undef, $id);
        1;
    } or $error = $@ || 'Telegram topic deletion failed';
    if ($error) {
        $self->dbh->do('UPDATE tickets SET telegram_error=? WHERE ticket_id=?', undef, substr("$error", 0, 255), $id);
        logger->error("Ticket $id: $error");
    }
}


1;
