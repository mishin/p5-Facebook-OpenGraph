package Facebook::OpenGraph;
use strict;
use warnings;
use Facebook::OpenGraph::Response;
use HTTP::Request::Common;
use URI;
use Furl::HTTP;
use Data::Recursive::Encode;
use JSON 2 qw(encode_json decode_json);
use Carp qw(croak);
use Digest::SHA qw(hmac_sha256);
use MIME::Base64::URLSafe qw(urlsafe_b64decode);
use Scalar::Util qw(blessed);

our $VERSION = '0.01';

sub new {
    my $class = shift;
    my $args  = shift || +{};

    return bless +{
        app_id       => $args->{app_id},
        secret       => $args->{secret},
        ua           => $args->{ua} || Furl::HTTP->new,
        namespace    => $args->{namespace},
        access_token => $args->{access_token},
        redirect_uri => $args->{redirect_uri},
        batch_limit  => $args->{batch_limit} || 50,
        is_beta      => $args->{is_beta} || 0,
    }, $class;
}

# accessors
sub app_id       { shift->{app_id}       }
sub secret       { shift->{secret}       }
sub ua           { shift->{ua}           }
sub namespace    { shift->{namespace}    }
sub access_token { shift->{access_token} }
sub redirect_uri { shift->{redirect_uri} }
sub batch_limit  { shift->{batch_limit}  }
sub is_beta      { shift->{is_beta}      }

sub uri {
    my ($self, $path) = @_;
    my $base = $self->is_beta ? 'https://graph.beta.facebook.com/'
                              : 'https://graph.facebook.com/';
    return URI->new_abs($path, $base);
}

sub video_uri {
    my ($self, $path) = @_;
    my $base = $self->is_beta ? 'https://graph-video.beta.facebook.com/'
                              : 'https://graph-video.facebook.com/';
    return URI->new_abs($path, $base);
}

# Using the signed_request Parameter: Step 1. Parse the signed_request
# https://developers.facebook.com/docs/howtos/login/signed-request/#step1
sub parse_signed_request {
    my ($self, $signed_request) = @_;
    croak 'signed_request is not given' unless $signed_request;
    croak 'secret key must be set' unless $self->secret;

    my ($enc_sig, $payload) = split(/\./, $signed_request);
    my $sig = urlsafe_b64decode($enc_sig);
    my $val = decode_json(urlsafe_b64decode($payload));

    croak 'algorithm must be HMAC-SHA256'
        unless uc($val->{algorithm}) eq 'HMAC-SHA256';

    my $expected_sig = hmac_sha256($payload, $self->secret);
    croak 'Signature does not match' unless $sig eq $expected_sig;

    return $val;
}

# OAuth Dialog: Constructing a URL to the OAuth Dialog
# https://developers.facebook.com/docs/reference/dialogs/oauth/
sub auth_uri {
    my ($self, $param_ref) = @_;
    $param_ref ||= +{};
    croak 'redirect_uri and app_id must be set'
        unless $self->redirect_uri && $self->app_id;

    if (my $scope_ref = ref $param_ref->{scope}) {
        $param_ref->{scope} =
            $scope_ref eq 'ARRAY' ? join ',', @{$param_ref->{scope}}
                                  : croak 'scope must be string or array ref';
    }
    $param_ref->{redirect_uri} = $self->redirect_uri;
    $param_ref->{client_id}    = $self->app_id;
    $param_ref->{display}      ||= 'page';
    my $base = $self->is_beta ? 'https://www.beta.facebook.com/'
                              : 'https://www.facebook.com/';
    my $uri = URI->new_abs('/dialog/oauth/', $base);
    $uri->query_form($param_ref);

    return $uri->as_string;
}

sub set_access_token {
    my ($self, $token) = @_;
    $self->{access_token} = $token;
}

# Login as an App: Step 1. Obtain an App Access Token
# https://developers.facebook.com/docs/howtos/login/login-as-app/#step1
sub get_app_token {
    my $self = shift;

    croak 'app_id and secret must be set' unless $self->app_id && $self->secret;
    my $token_ref = $self->_get_token(+{grant_type => 'client_credentials'});
    return $token_ref->{access_token};
}

# Login for Server-side Apps: Step 6. Exchange the code for an Access Token
# https://developers.facebook.com/docs/howtos/login/server-side-login/#step6
sub get_user_token_by_code {
    my ($self, $code) = @_;

    croak 'code is not given' unless $code;
    croak 'redirect_uri must be set' unless $self->redirect_uri;

    my $query_ref = +{
        redirect_uri => $self->redirect_uri,
        code         => $code,
    };
    my $token_ref = $self->_get_token($query_ref);
    croak 'expires is not returned' unless $token_ref->{expires};

    return $token_ref;
}

sub _get_token {
    my ($self, $param_ref) = @_;

    $param_ref = +{
        %$param_ref,
        client_id     => $self->app_id,
        client_secret => $self->secret,
    };

    my $response = $self->request('GET', '/oauth/access_token', $param_ref);
    # Get access_token from response content
    # content should be 'access_token=12345|QwerTy&expires=5183951' formatted
    my $res_content = $response->content;
    my $token_ref = +{URI->new('?'.$res_content)->query_form};
    croak 'can\'t get access_token properly: '.$res_content
        unless $token_ref->{access_token};

    return $token_ref;
}

sub get {
    return shift->request('GET', @_)->as_hashref;
}

sub post {
    return shift->request('POST', @_)->as_hashref;
}

*fetch   = \&get;
*publish = \&post;

# Using ETags
# https://developers.facebook.com/docs/reference/ads-api/etags-reference/
sub fetch_with_etag {
    my ($self, $uri, $param_ref, $etag) = @_;

    # Attach ETag value to header
    # Returns status 304 w/o contnet or status 200 w/ modified content
    my $header   = ['IF-None-Match' => $etag];
    my $response = $self->request('GET', $uri, $param_ref, $header);

    return $response->is_modified ? $response->as_hashref
                                  : undef;
}

sub bulk_fetch {
    my ($self, $paths_ref) = @_;

    my @queries = map {
        +{method => 'GET', relative_url => $_}
    } @$paths_ref;

    return $self->batch(\@queries);
}

# Batch Requests
# https://developers.facebook.com/docs/reference/api/batch/
sub batch {
    my $self  = shift;
    my $batch = shift;

    my $responses_ref = $self->batch_fast($batch, @_);

    # Devide response content and create response objects that correspond to each request
    my @data = ();
    for my $r (@$responses_ref) {
        for my $res_ref (@$r) {
            my @headers  = map {
                $_->{name} => $_->{value}
            } @{$res_ref->{headers}};
            my $response = $self->create_response(
                $res_ref->{code},
                $res_ref->{message},
                \@headers,
                $res_ref->{body},
            );
            croak $response->error_string unless $response->is_success;
            push @data, $response->as_hashref;
        }
    }

    return \@data;
}

# doesn't create F::OG::Response object for each response
sub batch_fast {
    my $self  = shift;
    my $batch = shift;

    # Other than HTTP header, you need to set access_token as top level parameter.
    # You can specify individual token for each request
    # so you can act as several other users and/or pages.
    croak 'Top level access_token must be set' unless $self->access_token;

    # "We currently limit the number of requests which can be in a batch to 50"
    my @responses = ();
    while(my @queries = splice @$batch, 0, $self->batch_limit) {
        for my $q (@queries) {
            if ($q->{method} eq 'POST' && $q->{body}) {
                my $body_ref = $self->prep_param($q->{body});
                my $uri = URI->new;
                $uri->query_form(%$body_ref);
                $q->{body} = $uri->query;
            }
        }
        push @responses, $self->post(
            '',
            +{
                access_token => $self->access_token,
                batch        => encode_json(\@queries),
            },
            @_,
        );
    }

    return \@responses;
}

# Facebook Query Language (FQL)
# https://developers.facebook.com/docs/reference/fql/
sub fql {
    my $self  = shift;
    my $query = shift;
    return $self->get('/fql', +{q => $query}, @_);
}

# Facebook Query Language (FQL): Multi-query
# https://developers.facebook.com/docs/reference/fql/#multi
sub bulk_fql {
    my $self  = shift;
    my $batch = shift;

    return $self->fql(encode_json($batch), @_);
}

# Graph API: Deleting
# https://developers.facebook.com/docs/reference/api/deleting/
sub delete {
    my $self      = shift;
    my $path      = shift;
    my $param_ref = shift || +{};

    # Try DELETE method as described in document.
    my $response = $self->request('DELETE', $path, $param_ref, @_);
    return $response->as_hashref if $response->is_success;

    # Sometimes sending DELETE method failes,
    # but POST method with method=delete works.
    # Weird...
    $param_ref = +{
        %$param_ref,
        method => 'delete',
    };
    return $self->post($path, $param_ref, @_);
}

sub request {
    my ($self, $method, $uri, $param_ref, $headers) = @_;

    $method    = uc $method;
    $uri       = $self->uri($uri) unless blessed($uri) && $uri->isa('URI');
    $param_ref = $self->prep_param(+{
        $uri->query_form(+{}),
        %{$param_ref || +{}},
    });
    $headers ||= [];
    push @$headers, (Authorization => sprintf('OAuth %s', $self->access_token))
        if $self->access_token;

    my $content = undef;
    if ($method eq 'POST') {

        if ($param_ref->{source}) {
            # post photo or video to /OBJECT_ID/(photos|videos)

            # When posting a video, use graph-video.facebook.com .
            # For other actions, use graph.facebook.com/VIDEO_ID/CONNECTION_TYPE
            $uri->host($self->video_uri->host) if $uri->path =~ /\/videos$/;

            push @$headers, (Content_Type => 'form-data');
            my $req = POST $uri, @$headers, Content => [%$param_ref];
            $content = $req->content;
            my $req_header = $req->headers;
            $headers = +[
                map {
                    my $k = $_;
                    map { ( $k => $_ ) } $req_header->header($_);
                } $req_header->header_field_names
            ];
        }
        else {
            # post simple params such as message, link, description, etc...
            $content = $param_ref;
        }
    }
    else {
        $uri->query_form($param_ref);
        $content = '';
    }

    my ($res_minor_version, $res_status, $res_msg, $res_headers, $res_content)
        = $self->ua->request(
            method  => $method,
            url     => $uri,
            headers => $headers,
            content => $content,
        );

    my $response = $self->create_response(
        $res_status, $res_msg, $res_headers, $res_content
    );
    croak $response->error_string unless $response->is_success;

    return $response;
}

sub create_response {
    my $self = shift;
    return Facebook::OpenGraph::Response->new(+{
        map {$_ => shift} qw/code message headers content/
    });
}

sub prep_param {
    my ($self, $param_ref) = @_;

    $param_ref = Data::Recursive::Encode->encode_utf8($param_ref || +{});

    # mostly for /APP_ID/accounts/test-users
    if (my $perms = $param_ref->{permissions}) {
        $param_ref->{permissions} = ref $perms ? join ',', @$perms : $perms;
    }

    # Source parameter contains file path.
    # It must be an array ref to work w/ HTTP::Request::Common.
    if (my $path = $param_ref->{source}) {
        $param_ref->{source} = ref $path ? $path : [$path];
    }

    # use Field Expansion
    if (my $field_ref = $param_ref->{fields}) {
        $param_ref->{fields} = $self->prep_fields_recursive($field_ref);
    }

    # Object API
    # https://developers.facebook.com/docs/opengraph/using-object-api/
    my $object = $param_ref->{object};
    if ($object && ref $object eq 'HASH') {
        $param_ref->{object} = encode_json($object);
    }

    return $param_ref;
}

# Field Expansion
# https://developers.facebook.com/docs/reference/api/field_expansion/
sub prep_fields_recursive {
    my ($self, $val) = @_;

    my $ref = ref $val;
    if (!$ref) {
        return $val;
    }
    elsif ($ref eq 'ARRAY') {
        return join ',', map { $self->prep_fields_recursive($_) } @$val;
    }
    elsif ($ref eq 'HASH') {
        my @strs = ();
        for my $k (keys %$val) {
            my $v = $val->{$k};
            my $r = ref $v;
            my $pattern = $r && $r eq 'HASH' ? '%s.%s' : '%s(%s)';
            push @strs, sprintf($pattern, $k, $self->prep_fields_recursive($v));
        }
        return join '.', @strs;
    }
}

# How-To: Publish an Action
# https://developers.facebook.com/docs/technical-guides/opengraph/publish-action/#create
sub publish_action {
    my $self   = shift;
    my $action = shift;
    croak 'namespace is not set' unless $self->namespace;
    return $self->post(sprintf('/me/%s:%s', $self->namespace, $action), @_);
}

# Test Users
# https://developers.facebook.com/docs/test_users/
sub create_test_users {
    my $self         = shift;
    my $settings_ref = shift;

    $settings_ref = [$settings_ref] unless ref $settings_ref eq 'ARRAY';

    my @settings = ();
    for my $setting (@$settings_ref) {
        push @settings, +{
            method       => 'POST',
            relative_url => sprintf('/%s/accounts/test-users', $self->app_id),
            body         => $setting,
        };
    }

    return $self->batch(\@settings);
}

# Updating Objects 
# https://developers.facebook.com/docs/technical-guides/opengraph/defining-an-object/#update
sub check_object {
    my ($self, $target) = @_;
    my $param_ref = +{
        id     => $target, # $target is object url or open graph object id
        scrape => 'true',
    };
    return $self->post('', $param_ref);
}

1;
__END__

=head1 NAME

Facebook::OpenGraph - Simple way to handle Facebook's Graph API.

=head1 VERSION

This is Facebook::OpenGraph version 0.01

=head1 SYNOPSIS
    
  use Facebook::OpenGraph;
  
  # fetching public information about given objects
  my $fb = Facebook::OpenGraph->new;
  my $user = $fb->fetch('zuck'); #
  my $page = $fb->fetch('oklahomer.docs');
  my $objs = $fb->bulk_fetch([qw/zuck oklahomer.docs/]);
  
  # get access_token for application
  my $token = Facebook::OpenGraph->new(+{
      app_id => $my_application_id,
      secret => $my_application_secret,
  })->get_app_token;
  
  # user authorization
  my $fb = Facebook::OpenGraph->new(+{
      app_id       => $my_application_id,
      secret       => $my_application_secret,
      namespace    => $my_application_namespace,
      redirect_uri => 'https://sample.com/auth_callback',
  });
  my $auth_url = $fb->auth_uri(+{
      scope => [qw/email publish_actions/],
  });
  $c->redirect($auth_url);
  
  my $req = Plack::Request->new($env);
  my $token_ref = $fb->get_user_token_by_code($req->query_param('code'));
  $fb->set_access_token($token_ref->{access_token});
  
  # publish photo
  $fb->publish('/me/photos', +{
      source  => '/path/to/pic.png',
      message => 'Hello world!',
  });
  
  # publish Open Graph Action
  $fb->publish_action($action_type, +{$object_type => $object_url});

=head1 DESCRIPTION

Facebook::OpenGraph is a Perl interface to handle Facebook's Graph API. This was inspired by L<Facebook::Graph>, but focused on simplicity and customizability because Facebook Platform modifies its API spec so frequently and we have to be able to handle it in shorter period of time.

=head1 METHODS

=head2 Class Methods

=head3 C<< Facebook::OpenGraph->new( $args ) :Facebook::OpenGraph >>

Creates and returns a new Facebook::OpenGraph object.

I<$args> can contain...

=over

=item app_id :Int

Facebook application ID.

=item secret :Str

Facebook application secret.

=item ua :Object

L<Furl::HTTP> object. Default is equivalent to Furl::HTTP->new;

=item namespace :Str

Facebook application namespace. This is used when you publish Open Graph Action.

=item access_token :Str

Access token for user, application or Facebook Page.

=item redirect_uri :Str

The URL to be used for authorization. Detail should be found at L<https://developers.facebook.com/docs/reference/dialogs/oauth/>.

=item batch_limit :Int = 50

The maximum # of queries that can be set w/in a single batch request. If the # of given queries exceeds this, then queries are divided into multiple batch requests and responses are combined so it seems just like a single request. Default value is 50 as API documentation says.

=item is_beta :Bool = 0

Weather to use beta tier.

=back

=head2 Instance Methods

=head3 C<< $fb->app_id() :Int >>

Accessor method that returns application id.

=head3 C<< $fb->secret() :Str >>

Accessor method that returns application secret.

=head3 C<< $fb->ua() :Object >>

Accessor method that returns L<Furl::HTTP> object.

=head3 C<< $fb->namespace() :Str >>

Accessor method that returns application namespace.

=head3 C<< $fb->access_token() :Str >>

Accessor method that returns access token.

=head3 C<< $fb->redirect_uri() :Str >>

Accessor method that returns uri that is used for user authorization.

=head3 C<< $fb->batch_limit() :Int >>

Accessor method that returns the maximum # of queries that can be set w/in a single batch request. If the # of given queries exceeds this, then queries are divided into multiple batch requests and responses are combined so it seems just like a single request. Default value is 50 as API documentation says.

=head3 C<< $fb->is_beta() :Bool >>

Accessor method that returns whether to use Beta tier or not.

=head3 C<< $fb->uri($path :Str) :Object >>

Returns URI object w/ the specified path. If is_beta returns true, the base url is https://graph.beta.facebook.com/ . Otherwise its base url is https://graph.facebook.com/ . C<request()> automatically determines if it should use C<uri()> or C<video_uri()> based on endpoint and parameters so you won't use C<uri()> or C<video_uri()> directly as long as you are using requesting methods that are provided in this module.

=head3 C<< $fb->video_uri($path :Str) :Object >>

Returns URI object w/ the specified path that should only be used when posting a video.

=head3 C<< $fb->parse_signed_request($signed_request_str :Str) :HashRef >>

It parses signed_request that Facebook Platform gives to your callback endpoint.

  my $req = Plack::Request->new($env);
  my $val = $fb->parse_signed_request($req->query_param('signed_request'));

=head3 C<< $fb->auth_uri($args :HashRef) :Str >>

Returns URL for Facebook OAuth dialog. You can redirect your user to this returning URL for authorization purpose.

  my $auth_url = $fb->auth_uri(+{
      display => 'page', # Dialog's display type. Default value is 'page.'
      scope   => [qw/email publish_actions/],
  });
  $c->redirect($auth_url);

=head3 C<< $fb->set_access_token($access_token :Str) >>

Set $access_token as the access token to use on C<request()>. C<access_token()> returns this value.

=head3 C<< $fb->get_app_token() :HashRef >>

Obtain an access token for application. Give the returning value to C<set_access_token()> and you can make request on behalf of your application.

=head3 C<< $fb->get_user_token_by_code($code :Str) :HashRef >>

Obtain an access token for user based on C<$code>. C<$code> should be given on your callback endpoint which is specified on C<$redirect_uri>. Give the returning access token to C<set_access_token()> and you can act on behalf of the user.

  # On OAuth callback page which you specified on $fb->redirect_uri.
  my $req          = Plack::Request->new($env);
  my $token_ref    = $fb->get_user_token_by_code($req->query_param('code'))
  my $access_token = $token_ref->{access_token};
  my $expires      = $token_ref->{expires};

=head3 C<< $fb->get($path :Str, $param_ref :HashRef, $headers_ref :ArrayRef) :HashRef >>

Alias to C<request()> that sends C<GET> request.

  my $path = 'zuck'; # should be ID or username
  my $user = $fb->get($path);
  #{
  #    name   => 'Mark Zuckerberg',
  #    id     => 4,
  #    locale => 'en_US',
  #}

=head3 C<< $fb->post($path :Str, $param_ref :HashRef, $headers_ref :ArrayRef) :HashRef >>

Alias to C<request()> that sends C<POST> request.

  my $res = $fb->publish('/me/photos', +{source => '/path/to/pic.png'});
  #{
  #    id      => 123456,
  #    post_id => '123456_987654',
  #
  #}

=head3 C<< $fb->fetch($path :Str, $param_ref :HashRef, $headers_ref :ArrayRef) :HashRef >>

Alias to C<get()> for those who got used to L<Facebook::Graph>

=head3 C<< $fb->publish($path :Str, $param_ref :HashRef, $headers_ref :ArrayRef) :HashRef >>

Alias to C<post()> for those who got used to L<Facebook::Graph>

=head3 C<< $fb->fetch_with_etag($path :Str, $params :HashRef, $etag_value :Str) >>

Alias to C<request()> that sends C<GET> request w/ given ETag value. Returns undef if requesting data is not modified. Otherwise it returns modified data.

  my $user = $fb->fetch_with_etag('/zuck', +{fields => 'email'}, $etag);

=head3 C<< $fb->bulk_fetch($paths_ref :ArrayRef) :ArrayRef >>

Request batch request and returns an array reference.

  my $data = $fb->bulk_fetch([qw/zuck go.hagiwara/]);
  #[
  #    {
  #        link => 'http://www.facebook.com/zuck',
  #        name => 'Mark Zuckerberg',
  #    },
  #    {
  #        link => 'http://www.facebook.com/go.hagiwara',
  #        name => 'Go Hagiwara',
  #    }
  #]


=head3 C<< $fb->batch($requests_ref :ArrayRef) :ArrayRef >>

Request batch request and returns an array reference.

  my $data = $fb->batch([
      +{method => 'GET', relative_url => 'zuck'},
      +{method => 'GET', relative_url => 'oklahomer.docs'},
  ]);

=head3 C<< $fb->batch_fast($requests_ref :ArrayRef) :ArrayRef >>

Request batch request and returns results as array reference, but it doesn't create L<Facebook::OpenGraph::Response> to handle each response.

  my $data = $fb->batch_fast([
      +{method => 'GET', relative_url => 'zuck'},
      +{method => 'GET', relative_url => 'oklahomer.docs'},
  ]);
  #[
  #    [
  #        {
  #            body    => {id => 4, name => 'Mark Zuckerberg', .....},
  #            headers => [ .... ],
  #            code    => 200,
  #        },
  #        {
  #            body    => {id => 204277149587596, name => 'Oklahomer', .....},
  #            headers => [ .... ],
  #            code    => 200,
  #        },
  #    ]
  #]

=head3 C<< $fb->fql($fql_query :Str) :HashRef >>

Alias to C<request()> that optimizes query parameter for FQL query and sends C<GET> request.

  my $res = $fb->fql('SELECT display_name FROM application WHERE app_id = 12345');
  #{
  #    data => [{
  #        display_name => 'app',
  #    }],
  #}

=head3 C<< $fb->bulk_fql($fql_queries_ref :ArrayRef) :HashRef >>

Alias to C<fql()> to request multiple FQL query at once.

  my $res = $fb->bulk_fql(+{
      'all friends' => 'SELECT uid2 FROM friend WHERE uid1 = me()',
      'my name'     => 'SELECT name FROM user WHERE uid = me()',
  });
  #{
  #    data => [
  #        {
  #            fql_result_set => [
  #                {uid2 => 12345},
  #                {uid2 => 67890},
  #            ],
  #            name => 'all friends',
  #        },
  #        {
  #            fql_result_set => [
  #                name => 'Michael Corleone'
  #            ],
  #            name => 'my name',
  #        },
  #    ],
  #}

=head3 C<< $fb->delete($path :Str, $param_ref :HashRef) :HashRef >>

Alias to C<request()> that sends DELETE request to delete object on Facebook's social graph. It sends POST request w/ method=delete query parameter when DELETE request fails. I know it's weird, but sometimes DELETE fails and POST w/ method=delete works.

  $fb->delete($object_id);

=head3 C<< $fb->request($request_method :Str, $path :Str, $param_ref :HashRef, $headers_ref :ArrayRef) :Facebook::OpenGraph::Response >>

Sends request to Facebook Platform and returns L<Facebook::Graph::Response> object.

=head3 C<< $fb->create_response($http_status_code :Int, $http_status_message :Str, $headers_ref :ArrayRef, $response_content :Str) :Facebook::OpenGraph::Response >>

Creates and returns L<Facebook::OpenGraph::Response>. If you wish to use customized response class, then override this method to return MyApp::Better::Response.

=head3 C<< $fb->prep_param($param_ref :HashRef) :HashRef >>

Handles sending parameters and format them in the way Graph API spec states. This method is called in C<request()> so you don't usually use this method directly.

=head3 C<< $fb->prep_fields_recursive($val :Any) :Str >>

Handles fields parameter and format it in the way Graph API spec states. This method is called in C<prep_param> which is called in C<request()> so you don't usually use this method directly.

=head3 C<< $fb->publish_action($action_type :Str, $param_ref :HashRef) :HashRef >>

Alias to C<request()> that optimizes body content and endpoint to sends C<POST> request to publish Open Graph Action.

  my $res = $fb->publish_action('give', +{crap => 'https://sample.com/poop/'});
  #{id => 123456}

=head3 C<< $fb->create_test_users($settings_ref :ArrayRef) :ArrayRef >>

  my $res = $fb->create_test_users([
      +{
          permissions => [qw/publish_actions/],
          locale      => 'en_US',
          installed   => 'true',
      },
      +{
          permissions => [qw/publish_actions email read_stream/],
          locale      => 'ja_JP', 
          installed   => 'true',
      }
  ])
  #[
  #    +{
  #        id           => 123456789,
  #        access_token => '5678uiop',
  #        login_url    => 'https://www.facebook.com/platform/test_account_login?user_id=123456789&n=asdfghh',
  #        email        => 'saffasdffad@tfbnw.net',
  #        password     => 67890,
  #    },
  #    +{
  #        id           => 1234567890,
  #        access_token => '5678uiopasadfasdfa',
  #        login_url    => 'https://www.facebook.com/platform/test_account_login?user_id=1234567890&n=asdfghdasdfash',
  #        email        => 'asdfghdasdfash@tfbnw.net',
  #        password     => 12345,
  #    },
  #];

Alias to C<request()> that optimizes to create test users for your application.

=head3 C<< $fb->check_object($target :Str) :HashRef >>

Alias to C<request()> that sends C<POST> request to Facebook Debugger to check/update object.

  $fb->check_object('https://sample.com/object/');
  $fb->check_object($object_id);
 
=head1 AUTHOR

Oklahomer E<lt>hagiwara dot go at gmail dot comE<gt>

=head1 SUPPORT

=over

=item Repository

L<https://github.com/oklahomer/p5-Facebook-OpenGraph/>

=item Bug Reports

L<https://github.com/oklahomer/p5-Facebook-OpenGraph/issues>

=back

=head1 SEE ALSO

L<Facebook::Graph>

=head1 LICENSE

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
