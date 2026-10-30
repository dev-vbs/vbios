package Core::Remnawave;
use v5.14;
use parent 'Core::Base';
use Core::Base;
use Core::System::ServiceManager qw(get_service);
use Core::Utils qw(decode_json now);

sub _cfg { get_service('config')->data_by_name('remna') || {} }
sub _transport { get_service('Core::Transport::Http') }
sub _request {
    my ($self,%a)=@_; my $cfg=$self->_cfg; die 'Remnawave URL is not configured' unless $cfg->{url}; die 'Remnawave API token is not configured' unless $cfg->{api_token};
    my $base=$cfg->{url}; $base =~ s{/+$}{}; my $resp=$self->_transport->http(url=>$base.$a{path},method=>$a{method}||'get',headers=>{Authorization=>'Bearer '.$cfg->{api_token},Accept=>'application/json'},content=>$a{content}||{});
    my $body=eval { $resp->json_content } || {};
    die 'Remnawave request failed (HTTP '.$resp->code.')' unless $resp->is_success;
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
    my $id=$data->{id} || $data->{user}{id} || $data->{response}{user}{id};
    if (!$id && $data->{shortUuid}) {
        my $resolved=$self->_request(path=>'/api/users/by-short-uuid/'.$data->{shortUuid});
        $id=$resolved->{response}{id} || $resolved->{id} || $resolved->{data}{id};
    }
    die 'Remnawave numeric user id is not found for this service' unless defined $id && "$id" =~ /^\d+$/;
    return int($id);
}
sub _limit { my ($self,$row)=@_; my $settings=eval { decode_json($row->{settings}||'{}') } || {}; return int($settings->{hwidDeviceLimit} || $settings->{hwid_device_limit} || 3) }
sub api_hwid_list { my ($self,%a)=@_; my $row=$self->_owned($self->user_id,$a{user_service_id}) or die 'service not found'; my $r=$self->_request(path=>'/api/hwid/devices/'.$self->_remna_id($row)); return { data=>$r->{response}{data} || $r->{response}{devices} || $r->{data} || $r->{devices} || $r->{result} || $r, limit=>$self->_limit($row) } }
sub _reset_count { my ($self,$uid,$usi)=@_; my $day=(localtime)[5]+1900 . sprintf('%02d',(localtime)[4]+1) . sprintf('%02d',(localtime)[3]); return $self->cache->increment('remna-hwid-'.$uid.'-'.$usi.'-'.$day,86400) }
sub api_hwid_delete { my ($self,%a)=@_; my $row=$self->_owned($self->user_id,$a{user_service_id}) or die 'service not found'; die 'hwid is required' unless defined $a{hwid} && length $a{hwid}; my $count=$self->_reset_count($self->user_id,$row->{user_service_id}); die 'daily HWID limit exceeded' if $count > $self->_limit($row); my $r=$self->_request(path=>'/api/hwid/devices/delete',method=>'post',content=>{userId=>$self->_remna_id($row),hwid=>$a{hwid}}); return { ok=>1,data=>$r } }
sub api_hwid_reset { my ($self,%a)=@_; my $row=$self->_owned($self->user_id,$a{user_service_id}) or die 'service not found'; my $list=$self->api_hwid_list(user_service_id=>$row->{user_service_id}); my $devices=$list->{data}; $devices=$devices->{devices} if ref($devices) eq 'HASH' && ref($devices->{devices}) eq 'ARRAY'; $devices=[] unless ref($devices) eq 'ARRAY'; my $n=scalar @$devices; return {ok=>1,deleted=>0} unless $n; my $count=$self->_reset_count($self->user_id,$row->{user_service_id}); die 'daily HWID limit exceeded' if $count+$n-1 > $self->_limit($row); my $r=$self->_request(path=>'/api/hwid/devices/delete-all',method=>'post',content=>{userId=>$self->_remna_id($row)}); return {ok=>1,deleted=>$n,data=>$r} }
1;
