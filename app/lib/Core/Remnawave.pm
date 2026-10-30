package Core::Remnawave;
use v5.14;
use parent 'Core::Base';
use Core::Base;
use Core::System::ServiceManager qw(get_service);
use Core::Utils qw(decode_json now);

sub _cfg { get_service('config')->data_by_name('remna') || {} }
sub _transport { get_service('Transport::Http') }
sub found_rows { 1 }
sub _request {
    my ($self,%a)=@_; my $cfg=$self->_cfg;
    die 'Remnawave URL is not configured' unless $cfg->{url};
    die 'Remnawave API token is not configured' unless $cfg->{api_token};
    my $base=$cfg->{url}; $base =~ s{/+$}{};
    my $method=lc($a{method} || 'get');
    my %request=(url=>$base.$a{path}, method=>$method,
        headers=>{Authorization=>'Bearer '.$cfg->{api_token},Accept=>'application/json'});
    $request{content_type}='application/json; charset=utf-8' if $method ne 'get';
    $request{content}=$a{content} if exists $a{content} && $method ne 'get';
    my $resp=$self->_transport->http(%request);
    my $body=eval { $resp->json_content };
    $body = {} unless defined $body;
    unless ($resp->is_success) {
        my $description = ref($body) eq 'HASH' ? ($body->{message} || $body->{error} || $body->{description} || $body->{response}{message} || '') : '';
        $description ||= eval { $resp->decoded_content } || '';
        $description = substr($description, 0, 300);
        $description =~ s/[\r\n]+/ /g;
        die 'Remnawave request failed: HTTP '.$resp->code.' '.($description || $resp->status_line).' ['.$method.' '.$a{path}.']';
    }
    return $body;
}
sub _owned {
    my ($self,$uid,$usi)=@_; return $self->dbh->selectrow_hashref('SELECT us.user_service_id,us.user_id,us.service_id,s.name,s.settings FROM user_services us JOIN services s ON s.service_id=us.service_id WHERE us.user_service_id=? AND us.user_id=?',undef,$usi,$uid);
}
sub _remna_id {
    my ($self,$row)=@_;
    my $cfg=$self->_cfg;
    my $prefix=$cfg->{storage_prefix} || 'vpn_mrzb_';
    my $data=eval { $self->srv('storage')->read(name=>$prefix.$row->{user_service_id}) } || {};
    my $id=$data->{id} || $data->{uuid} || $data->{user}{id} || $data->{user}{uuid} || $data->{response}{user}{id} || $data->{response}{user}{uuid};
    if (!$id && $data->{shortUuid}) {
        my $resolved=$self->_request(path=>'/api/users/by-short-uuid/'.$data->{shortUuid});
        $id=$resolved->{response}{id} || $resolved->{response}{uuid} || $resolved->{id} || $resolved->{uuid} || $resolved->{data}{id} || $resolved->{data}{uuid};
    }
    if (!$id) {
        my $prefix=$cfg->{username_prefix} || 'vBios_us_';
        my $resolved=eval { $self->_request(path=>'/api/users/by-username/'.$prefix.$row->{user_service_id}) } || {};
        $id=$resolved->{response}{id} || $resolved->{response}{uuid} || $resolved->{id} || $resolved->{uuid} || $resolved->{data}{id} || $resolved->{data}{uuid} || $resolved->{response}{user}{id} || $resolved->{response}{user}{uuid};
    }
    die 'Remnawave numeric user id is not found for this service' unless defined $id && "$id" =~ /^\d+$/ && $id > 0;
    return int($id);
}
sub _limit { my ($self,$row)=@_; my $settings=eval { decode_json($row->{settings}||'{}') } || {}; return int($settings->{hwidDeviceLimit} || $settings->{hwid_device_limit} || 3) }
sub api_hwid_list {
    my ($self,%a)=@_;
    my $result;
    my $ok = eval {
        my $row=$self->_owned($self->user_id,$a{user_service_id}) or die 'service not found';
        my $r=$self->_request(path=>'/api/hwid/devices/'.$self->_remna_id($row));
        my $payload=$r->{response} || $r;
        my $devices=ref($payload) eq 'ARRAY' ? $payload : ($payload->{devices});
        die 'unexpected Remnawave devices response' unless ref($devices) eq 'ARRAY';
        $result={devices=>$devices,limit=>$self->_limit($row)};
        1;
    };
    unless ($ok) {
        my $error = $@ || 'unknown request error';
        $error =~ s/[\r\n]+/ /g;
        get_service('report')->status(400);
        get_service('report')->add_error('HWID: '.$error);
        return undef;
    }
    return $result;
}
sub _reset_count { my ($self,$uid,$usi)=@_; my $day=(localtime)[5]+1900 . sprintf('%02d',(localtime)[4]+1) . sprintf('%02d',(localtime)[3]); return $self->cache->increment('remna-hwid-'.$uid.'-'.$usi.'-'.$day,86400) }
sub _api_error { my ($self,$error)=@_; $error ||= 'unknown request error'; $error =~ s/[\r\n]+/ /g; get_service('report')->status(400); get_service('report')->add_error('HWID: '.substr($error,0,500)); return undef }
sub api_hwid_delete { my ($self,%a)=@_; my $result; my $ok=eval { my $row=$self->_owned($self->user_id,$a{user_service_id}) or die 'service not found'; die 'hwid is required' unless defined $a{hwid} && length $a{hwid}; my $count=$self->_reset_count($self->user_id,$row->{user_service_id}); die 'daily HWID limit exceeded' if $count > $self->_limit($row); my $r=$self->_request(path=>'/api/hwid/devices/delete',method=>'post',content=>{userId=>$self->_remna_id($row),hwid=>$a{hwid}}); $result={ok=>1,data=>$r}; 1 }; return $ok ? $result : $self->_api_error($@) }
sub api_hwid_reset { my ($self,%a)=@_; my $result; my $ok=eval { my $row=$self->_owned($self->user_id,$a{user_service_id}) or die 'service not found'; my $list=$self->api_hwid_list(user_service_id=>$row->{user_service_id}) or die 'unable to read HWID devices'; my $devices=$list->{devices}; $devices=[] unless ref($devices) eq 'ARRAY'; my $n=scalar @$devices; if (!$n) { $result={ok=>1,deleted=>0}; } else { my $count=$self->_reset_count($self->user_id,$row->{user_service_id}); die 'daily HWID limit exceeded' if $count+$n-1 > $self->_limit($row); my $r=$self->_request(path=>'/api/hwid/devices/delete-all',method=>'post',content=>{userId=>$self->_remna_id($row)}); $result={ok=>1,deleted=>$n,data=>$r}; } 1 }; return $ok ? $result : $self->_api_error($@) }
1;
