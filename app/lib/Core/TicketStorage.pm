package Core::TicketStorage;
use strict;
use warnings;
use MIME::Base64 qw(decode_base64);
use Digest::SHA qw(sha256_hex);
use HTTP::Request;
use LWP::UserAgent;
use Core::S3;

sub new {
    my ($class,$cfg)=@_;
    die 'Ticket storage configuration is required' unless ref($cfg) eq 'HASH';
    my %c=%$cfg;
    $c{access_key}=$ENV{TICKET_S3_ACCESS_KEY} || $c{access_key};
    $c{secret_key}=$ENV{TICKET_S3_SECRET_KEY} || $c{secret_key};
    die 'Ticket S3 credentials are missing' unless $c{access_key} && $c{secret_key};
    die 'Invalid ticket bucket' unless ($c{bucket}||'') =~ /\A[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]\z/;
    # Only the Yandex HTTPS endpoint: configuration cannot redirect secrets elsewhere.
    $c{endpoint}='https://storage.yandexcloud.net';
    $c{region}='ru-central1';
    return bless {config=>\%c},$class;
}

sub decode_image {
    my ($class,$encoded)=@_;
    die 'Image is required' unless defined $encoded && length $encoded;
    die 'Image exceeds 5 MiB' if length($encoded)>6990508;
    die 'Invalid base64 image' unless $encoded =~ /\A(?:[A-Za-z0-9+\/]{4})*(?:[A-Za-z0-9+\/]{2}==|[A-Za-z0-9+\/]{3}=)?\z/;
    my $bytes=decode_base64($encoded);
    die 'Image exceeds 5 MiB' if length($bytes)>5*1024*1024;
    my ($mime,$ext);
    if (substr($bytes,0,8) eq "\x89PNG\r\n\x1a\n") {($mime,$ext)=('image/png','png')}
    elsif (substr($bytes,0,3) eq "\xff\xd8\xff") {($mime,$ext)=('image/jpeg','jpg')}
    elsif (substr($bytes,0,6) =~ /\AGIF8[79]a\z/) {($mime,$ext)=('image/gif','gif')}
    elsif (length($bytes)>=12 && substr($bytes,0,4) eq 'RIFF' && substr($bytes,8,4) eq 'WEBP') {($mime,$ext)=('image/webp','webp')}
    else {die 'Only JPEG, PNG, WebP and GIF images are supported'}
    return ($bytes,$mime,$ext);
}

sub key {
    my ($self,$uid,$ext)=@_;
    die 'Invalid owner' unless $uid =~ /\A[1-9][0-9]*\z/;
    open my $random,'<:raw','/dev/urandom' or die 'Secure random source unavailable';
    read($random,my $nonce,24)==24 or die 'Secure random read failed';
    close $random;
    return 'tickets/'.$uid.'/'.unpack('H*',$nonce).'.'.$ext;
}

sub request {
    my ($self,$method,$bucket,$key,$body,$mime)=@_;
    die 'Invalid object key' unless $key =~ /\Atickets\/[1-9][0-9]*\/[a-f0-9]{48}\.(?:jpg|png|webp|gif)\z/;
    die 'Invalid bucket' unless $bucket =~ /\A[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]\z/;
    my $c=$self->{config};
    my $s3=bless {},'Core::S3';
    $s3->init(%$c);
    my $path="/$bucket/$key";
    $body='' unless defined $body;
    my $headers=$s3->_auth_header(method=>$method,canonical_uri=>$path,host=>'storage.yandexcloud.net',payload_hash=>sha256_hex($body));
    my $req=HTTP::Request->new($method=>$c->{endpoint}.$path);
    $req->header(%$headers);
    $req->header('X-Amz-Content-Sha256'=>sha256_hex($body));
    $req->header('Content-Type'=>$mime) if $mime;
    $req->content($body);
    # Never follow redirects with signed credentials; no request body/token logging.
    my $ua=LWP::UserAgent->new(timeout=>30,max_redirect=>0,ssl_opts=>{verify_hostname=>1});
    my $res=$ua->request($req);
    die 'Ticket object storage HTTP '.$res->code unless $res->is_success;
    return $res->content;
}
1;
