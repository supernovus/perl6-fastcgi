use v6;

class FastCGI::Connection;

use HTTP::Status;
use FastCGI::Request;
use FastCGI::Errors;
use FastCGI::Constants;
use FastCGI::Protocol;
use FastCGI::Protocol::Constants :ALL;

has $.socket;
has $.parent;
has $.err = FastCGI::Errors.new;
has %!requests;
has $!closed = False;

method handle-requests (&closure)
{
  loop
  {
    my Buf $header = $.socket.read(FCGI_HEADER_LEN);
    my ($type, $id, $content-length) = parse_header($header);
    my Buf $record = $header ~ $.socket.read($content-length);
    my %record = parse_record($record);
#    my $id = %record<request-id>;
#    my $type = %record<type>;
    given $type
    {
      when FCGI_BEGIN_REQUEST
      {
        if %!requests.exists($id) { die "Request of id $id already exists"; }
        %!requests{$id} = FastCGI::Request.new(:$id, :connection(self));
      }
      when FCGI_PARAMS
      {
        if ! %!requests.exists($id) { die "Invalid request id: $id"; }
        my $req = %!requests{$id};
        if %record<content>
        {
          $req.param(%record<content>);
        }
      }
      when FCGI_STDIN
      {
        if ! %!requests.exists($id) { die "Invalid request id: $id"; }
        my $req = %!requests{$id};
        if %record<content>
        {
          $req.in(%record<content>);
        }
        else
        {
          my $return = &closure($req.env);
          self.send-response($id, $return);
          %!requests.delete($id);
          if ! $.parent.multiplex { return; }
        }
      }
      when FCGI_GET_VALUES
      {
        if $id != FCGI_NULL_REQUEST_ID
        {
          die "Invalid management request.";
        }
        self.send-values(%record<values>);
        if ! $.parent.multiplex { return; }
      }
      ## TODO: FCGI_UNKNOWN_TYPE handling.
    }
  }
}

## Send management values.
method send-values (%wanted)
{
  my %values;
  for %wanted.keys -> $wanted
  {
    given $wanted
    {
      when FCGI_MAX_CONNS
      {
        %values{FCGI_MAX_CONNS} = $.parent.max-connections;
      }
      when FCGI_MAX_REQS
      {
        %values{FCGI_MAX_REQS} = $.parent.max-requests;
      }
      when FCGI_MPXS_CONNS
      {
        %values{FCGI_MPXS_CONNS} = $.parent.multiplex ?? 1 !! 0;
      }
    }
  }
  my $values = build_params(%values);
  my $res = build_record(FCGI_GET_VALUES_RESULT, FCGI_NULL_REQUEST_ID, $values);
  $.socket.write($res);
}

method send-response ($request-id, $response-data)
{
  my $http_message;
  if $.parent.PSGI
  {
    my $code = $response-data[0];
    my $message = get_http_status_msg($code);
    my $headers = "Status: $code $message"~CRLF;
    for @($response-data[1]) -> $header
    {
      $headers ~= $header.key ~ ": " ~ $header.value ~ CRLF;
    }
    $http_message = ($headers~CRLF).encode;
    for @($response-data[2]) -> $body
    {
      if $body ~~ Buf
      {
        $http_message ~= $body;
      }
      else
      {
        $http_message ~= $body.Str.encode;
      }
    }
  }
  else
  {
    if $response-data ~~ Buf
    {
      $http_message = $response-data;
    }
    else
    {
      $http_message = $response-data.Str.encode;
    }
  }

  my $res;
  if $.err.messages.elems > 0
  {
    my $errors = '';
    for $.err.messages -> $emsg
    {
      $errors ~= $emsg.decode;
    }
    $res = build_end_request($request-id, $http_message, $errors);
  }
  else
  {
    $res = build_end_request($request-id, $http_message);
  }

  $.socket.write($res);
}

method close
{
  $!socket.close if $!socket;
  $!closed = True;
}

submethod DESTROY
{
  self.close unless $!closed;
}

