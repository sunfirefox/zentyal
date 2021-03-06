# Copyright (C) 2008-2013 Zentyal S.L.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License, version 2, as
# published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
use strict;
use warnings;

package EBox::CGI::Base;

use HTML::Mason;
use HTML::Mason::Exceptions;
use CGI;
use EBox::Gettext;
use EBox;
use EBox::Global;
use EBox::CGI::Run;
use EBox::Exceptions::Base;
use EBox::Exceptions::Internal;
use EBox::Exceptions::External;
use EBox::Exceptions::DataMissing;
use EBox::Util::GPG;
use POSIX qw(setlocale LC_ALL);
use Error qw(:try);
use Encode qw(:all);
use Data::Dumper;
use Perl6::Junction qw(all);
use File::Temp qw(tempfile);
use File::Basename;
use Apache2::Connection;
use Apache2::RequestUtil;
use JSON::XS;

## arguments
##      title [optional]
##      error [optional]
##      msg [optional]
##      cgi   [optional]
##      template [optional]
sub new # (title=?, error=?, msg=?, cgi=?, template=?)
{
    my $class = shift;
    my %opts = @_;
    my $self = {};
    $self->{title} = delete $opts{title};
    $self->{crumbs} = delete $opts{crumbs};
    $self->{olderror} = delete $opts{error};
    $self->{msg} = delete $opts{msg};
    $self->{cgi} = delete $opts{cgi};
    $self->{template} = delete $opts{template};
    unless (defined($self->{cgi})) {
        $self->{cgi} = new CGI;
    }
    $self->{paramsKept} = ();

    bless($self, $class);
    return $self;
}

sub _header
{
}

sub _top
{
}

sub _menu
{
}

sub _title
{
    my $self = shift;

    my $title = $self->{title};
    my $crumbs = $self->{crumbs};

    my $filename = EBox::Config::templates . '/title.mas';
    my $interp = $self->_masonInterp();
    my $comp = $interp->make_component(comp_file => $filename);

    my @params = (title => $title, crumbs => $crumbs);

    $interp->exec($comp, @params);
}

sub _print_error # (text)
{
    my ($self, $text) = @_;
    $text or return;
    ($text ne "") or return;
    my $filename = EBox::Config::templates . '/error.mas';
    my $interp = $self->_masonInterp();
    my $comp = $interp->make_component(comp_file => $filename);
    my @params = ();
    push(@params, 'error' => $text);
    $interp->exec($comp, @params);
}

sub _error #
{
    my $self = shift;
    defined($self->{olderror}) and $self->_print_error($self->{olderror});
    defined($self->{error}) and $self->_print_error($self->{error});
}

sub _msg
{
    my $self = shift;
    defined($self->{msg}) or return;
    my $filename = EBox::Config::templates . '/msg.mas';
    my $interp = $self->_masonInterp();
    my $comp = $interp->make_component(comp_file => $filename);
    my @params = ();
    push(@params, 'msg' => $self->{msg});
    $interp->exec($comp, @params);
}

sub _body
{
    my $self = shift;
    defined($self->{template}) or return;

    my $filename = EBox::Config::templates . $self->{template};
    if (-f "$filename.custom") {
        # Check signature
        if (EBox::Util::GPG::checkSignature("$filename.custom")) {
            $filename = "$filename.custom";
            EBox::info("Using custom $filename");
        } else {
            EBox::warn("Invalid signature in $filename");
        }

    }
    my $interp = $self->_masonInterp();
    my $comp = $interp->make_component(comp_file => $filename);
    $interp->exec($comp, @{$self->{params}});
}

MASON_INTERP: {
    my $masonInterp;

    sub _masonInterp
    {
        my ($self) = @_;

        return $masonInterp if defined $masonInterp;

        $masonInterp = HTML::Mason::Interp->new(
            comp_root => EBox::Config::templates,
            escape_flags => {
                h => \&HTML::Mason::Escapes::basic_html_escape,
            },
        );
        return $masonInterp;
    }
};

sub _footer
{
}

sub _print
{
    my ($self) = @_;

    my $json = $self->{json};
    if ($json) {
        $self->JSONReply($json);
        return;
    }

    $self->_header;
    $self->_top;
    $self->_menu;
    print '<div id="limewrap"><div id="content">';
    $self->_title;
    $self->_error;
    $self->_msg;
    $self->_body;
    print "</div></div>";
    $self->_footer;
}

# alternative print for CGI runs in popup
# it hs been to explicitly called instead of
# the regular print. For example, overlaoding print and calling this
sub _printPopup
{
    my ($self) = @_;
    my $json = $self->{json};
    if ($json) {
        $self->JSONReply($json);
        return;
    }

    print($self->cgi()->header(-charset=>'utf-8'));
    print '<div id="limewrap"><div>';
    $self->_error;
    $self->_msg;
    $self->_body;
    print "</div></div>";
}

sub _checkForbiddenChars
{
    my ($self, $value) = @_;
    POSIX::setlocale(LC_ALL, EBox::locale());

    unless ( $value =~ m{^[\w /.?&+:\-\@,=\{\}]*$} ) {
        my $logger = EBox::logger;
        $logger->info("Invalid characters in param value $value.");
        $self->{error} ='The input contains invalid characters';
        throw EBox::Exceptions::External(__("The input contains invalid " .
            "characters. All alphanumeric characters, plus these non " .
           "alphanumeric chars: ={},/.?&+:-\@ and spaces are allowed."));
        if (defined($self->{redirect})) {
            $self->{chain} = $self->{redirect};
        }
        return undef;
    }
    no locale;
}

sub _loggedIn
{
    my $self = shift;
    # TODO
    return 1;
}

# arguments
#   - name of the required parameter
#   - display name for the parameter (as seen by the user)
sub _requireParam # (param, display)
{
    my ($self, $param, $display) = @_;

    unless (defined($self->unsafeParam($param)) && $self->unsafeParam($param) ne "") {
        $display or
            $display = $param;
        throw EBox::Exceptions::DataMissing(data => $display);
    }
}

# arguments
#   - name of the required parameter
#   - display name for the parameter (as seen by the user)
sub _requireParamAllowEmpty # (param, display)
{
    my ($self, $param, $display) = @_;

    foreach my $cgiparam (@{$self->params}){
        return if ($cgiparam =~ /^$param$/);
    }

    throw EBox::Exceptions::DataMissing(data => $display);
}

sub run
{
    my $self = shift;

    if (not $self->_loggedIn) {
        $self->{redirect} = "/Login/Index";
    } else {
        try {
            $self->_validateReferer();
            $self->_process();
        } catch EBox::Exceptions::Internal with {
            my $e = shift;
            throw $e;
        } catch EBox::Exceptions::Base with {
            my $e = shift;
            $self->setErrorFromException($e);
            if (defined($self->{redirect})) {
                $self->{chain} = $self->{redirect};
            }
        } otherwise {
            my $e = shift;
            throw $e;
        };
    }

    if (defined($self->{error})) {
        #only keep the parameters in paramsKept
        my $params = $self->params;
        foreach my $param (@{$params}) {
            unless (grep /^$param$/, @{$self->{paramsKept}}) {
                $self->{cgi}->delete($param);
            }
        }
        if (defined($self->{errorchain})) {
            if ($self->{errorchain} ne "") {
                $self->{chain} = $self->{errorchain};
            }
        }
    }

    if (defined($self->{chain})) {
        my $classname = EBox::CGI::Run->urlToClass($self->{chain});
        if (not $self->isa($classname)) {
            eval "use $classname";
            if ($@) {
                throw EBox::Exceptions::Internal("Cannot load $classname. Error: $@");
            }
            my $chain = $classname->new('error' => $self->{error},
                                        'msg' => $self->{msg},
                                        'cgi' => $self->{cgi});
            $chain->run;
            return;
        }
    }

    if (defined ($self->{redirect}) and not defined ($self->{error})) {
        my $request = Apache2::RequestUtil->request();
        my $headers = $request->headers_in();

        my $via = $headers->{'Via'};
        my $host = $headers->{'Host'};
        my $referer = $headers->{'Referer'};

        my $fwhost = $headers->{'X-Forwarded-Host'};
        my $fwproto = $headers->{'X-Forwarded-Proto'};
        # If the connection comes from a Proxy,
        # redirects with the Proxy IP address
        if (defined ($via) and defined ($fwhost)) {
            $host = $fwhost;
        }

        my ($protocol, $port) = $referer =~ m{(.+)://.+:(\d+)/};
        if (defined ($fwproto)) {
            $protocol = $fwproto;
        }

        my $url = "$protocol://$host";
        if ($port) {
            $url .= ":$port";
        }
        $url .= "/$self->{redirect}";

        print ($self->cgi()->redirect($url));
        return;
    }

    try  {
        $self->_print();
    } catch EBox::Exceptions::Base with {
        my $ex = shift;
        $self->setErrorFromException($ex);
        $self->_print_error($self->{error});
    } otherwise {
        my $ex = shift;
        my $logger = EBox::logger;
        if (isa_mason_exception($ex)) {
            $logger->error($ex->as_text);
            my $error = __("An internal error related to ".
                           "a template has occurred. This is ".
                           "a bug, relevant information can ".
                           "be found in the logs.");
            $self->_print_error($error);
        } elsif ($ex->isa('APR::Error')) {
            my $debug = EBox::Config::boolean('debug');
            my $error = $debug ? $ex->confess() : $ex->strerror();
            $self->_print_error($error);
        } else {
            # will be logged in EBox::CGI::Run
            throw $ex;
        }
    };
}

# Method: unsafeParam
#
#     Get the CGI parameter value in an unsafe way allowing all
#     character
#
#     This is a security risk and it must be used with caution
#
# Parameters:
#
#     param - String the parameter's name to get the value from
#
# Returns:
#
#     string - the parameter's value without any security check if the
#     context is scalar
#
#     array - containing the string values for the given parameter if
#     the context is an array
#
sub unsafeParam # (param)
{
    my ($self, $param) = @_;
    my $cgi = $self->cgi;
    my @array;
    my $scalar;
    if (wantarray) {
        @array = $cgi->param($param);
        (@array) or return undef;
        foreach my $v (@array) {
            utf8::decode($v);
        }
        return @array;
    } else {
        $scalar = $cgi->param($param);
        #check if $param.x exists for input type=image
        unless (defined($scalar)) {
            $scalar = $cgi->param($param . ".x");
        }
        defined($scalar) or return undef;
        utf8::decode($scalar);
        return $scalar;
    }
}

sub param # (param)
{
    my ($self, $param) = @_;
    my $cgi = $self->cgi;
    my @array;
    my $scalar;
    if (wantarray) {
        @array = $cgi->param($param);
        (@array) or return undef;
        my @ret = ();
        foreach my $v (@array) {
            utf8::decode($v);
            $v =~ s/\t/ /g;
            $v =~ s/^ +//;
            $v =~ s/ +$//;
            $self->_checkForbiddenChars($v);
            push(@ret, $v);
        }
        return @ret;
    } else {
        $scalar = $cgi->param($param);
        #check if $param.x exists for input type=image
        unless (defined($scalar)) {
            $scalar = $cgi->param($param . ".x");
        }
        defined($scalar) or return undef;
        utf8::decode($scalar);
        $scalar =~ s/\t/ /g;
        $scalar =~ s/^ +//;
        $scalar =~ s/ +$//;
        $self->_checkForbiddenChars($scalar);
        return $scalar;
    }
}

# Method: params
#
#      Get the CGI parameters
#
# Returns:
#
#      array ref - containing the CGI parameters
#
sub params
{
    my ($self) = @_;

    my $cgi = $self->cgi;
    my @names = $cgi->param;

    # Prototype adds a '_' empty param to Ajax POST requests when the agent is
    # webkit based
    @names = grep { !/^_$/ } @names;

    foreach (@names) {
        $self->_checkForbiddenChars($_);
    }

    return \@names;
}

sub keepParam # (param)
{
    my ($self, $param) = @_;
    push(@{$self->{paramsKept}}, $param);
}

sub cgi
{
    my $self = shift;
    return $self->{cgi};
}

# Method: setTemplate
#   set the html template used by the CGI. The template can also be set in the constructor/
#
# Parameters:
#   $template - the template path relative to the template root
#
# See also:
#    new
sub setTemplate
{
    my ($self, $template) = @_;
    $self->{template} = $template;
}

# Method: _process
#  process the CGI
#
# Default behaviour:
#     the default behaviour is intended to standarize and ease some common operations so do not override it except for backward compability or special reasons.
#     The default behaviour validate the peresence or absence or CGI parameters using requiredParameters and optionalParameters method, then it calls the method actuate, where the functionality of CGI resides,  and finally uses masonParameters to get the parameters needed by the html template invocation.
sub _process
{
    my ($self) = @_;

    $self->_validateParams();
    $self->actuate();
    $self->{params} = $self->masonParameters();
}

# Method: setMsg
#   sets the message attribute
#
# Parameters:
#   $msg - message to be setted
sub setMsg
{
    my ($self, $msg) = @_;
    $self->{msg} = $msg;
}

# Method: setError
#   set the error message
#
# Parameters:
#   $error - message to be setted
sub setError
{
    my ($self, $error) = @_;
    $self->{error} = $error;
}

# Method: setErrorFromException
#    set the error message eusing the description value found in a exception
#
# Parameters:
#  $ex - exception used to set the error attributer
sub setErrorFromException
{
    my ($self, $ex) = @_;

    my $dump = EBox::Config::configkey('dump_exceptions');
    if (defined ($dump) and ($dump eq 'yes')) {
        $self->{error} = $ex->stringify() if $ex->can('stringify');
        $self->{error} .= "<br/>\n";
        $self->{error} .= "<pre>\n";
        $self->{error} .= Dumper($ex);
        $self->{error} .= "</pre>\n";
        $self->{error} .= "<br/>\n";
        return;
    }

    if ($ex->isa('EBox::Exceptions::External')) {
        $self->{error} = $ex->stringify();
        return;
    }

    my $debug = EBox::Config::configkey('debug');
    if ($debug eq 'yes') {
        my $log = '';
        $log = $ex->stringify() if $ex->can('stringify');
        $log .= Dumper($ex);
        EBox::debug($log);
    }

    if ($ex->isa('EBox::Exceptions::Internal')) {
        $self->{error} = __("An internal error has ".
                "occurred. This is most probably a ".
                "bug, relevant information can be ".
                "found in the logs.");
    } elsif ($ex->isa('EBox::Exceptions::Base')) {
        $self->{error} = __("An unexpected internal ".
                "error has occurred. This is a bug, ".
                "relevant information can be found ".
                "in the logs.");
    } else {
        $self->{error} = __('Sorry, you have just hit a bug in Zentyal.');
    }

    my $reportHelp = __x('Please look for the details in the {f} file and take a minute to {oh}submit a bug report{ch} so we can fix the issue as soon as possible.',
                         f => '/var/log/zentyal/zentyal.log', oh => '<a href="http://trac.zentyal.org/newticket">', ch => '</a>');
    $self->{error} .= " $reportHelp";
}

# Method: setRedirect
#    sets the redirect attribute. If redirect is set to some value, the parent class will do an HTTP redirect after the _process method returns.
#
# An HTTP redirect makes the browser issue a new HTTP request, so all the status data in the old request gets lost, but there are cases when you want to keep that data for the new CGI. This could be done using the setChain method instead
#
# When an error happens you don't want redirects at all, as the error message would be lost. If an error happens and redirect has been set, then that value is used as if it was chain.
#
# Parameters:
#   $redirect - value for the redirect attribute
#
# See also:
#  setRedirect, setErrorchain
sub setRedirect
{
    my ($self, $redirect) = @_;
    $self->{redirect} = $redirect;
}

# Method: setChain
#    set the chain attribute. It works exactly the same way as redirect attribute but instead of sending an HTTP response to the browser, the parent class parses the url, instantiates the matching CGI, copies all data into it and runs it. Messages and errors are copied automatically, the parameters in the HTTP request are not, since an error caused by one of#  them could propagate to the next CGI.
#
# If you need to keep HTTP parameters you can use the keepParam method in the parent class. It takes the name of the parameter as an argument and adds it to the list of parameters that will be copied to the new CGI if a "chain" is performed.
#
#
# Parameters:
#   $chain - value for the chain attribute
#
# See also:
#  setRedirect, setErrorchain, keepParam
sub setChain
{
    my ($self, $chain) = @_;
    $self->{chain} = $chain;
}

# Method: setErrorchain
#    set the errorchain attribute. Sometimes you want to chain to a different CGI if there is an error, for example if the cause of the error is the absence of an input parameter necessary to show the page. If that's the case you can set the errorchain attribute, which will have a higher priority than chain and redirect if there's an error.
#
# Parameters:
#   $errorchain - value for the errorchain attribute
#
# See also:
#  setChain, setRedirect
sub setErrorchain
{
    my ($self, $errorchain) = @_;
    $self->{errorchain} = $errorchain;
}

# Method: paramsAsHash
#
# Returns: a reference to a hash which contains the CGI parameters and
#    its values as keys and values of the hash
#
# Possible implentation improvements:
#  maybe it will be good idea cache this in some field of the instance
#
# Warning:
#   there is not unsafe parameters check there, do it by hand if you need it
sub paramsAsHash
{
    my ($self) = @_;

    my @names = @{ $self->params() };
    my %params = map {
      my $value =  $self->unsafeParam($_);
      $_ => $value
    } @names;

    return \%params;
}

sub _validateParams
{
    my ($self) = @_;
    my $params_r    = $self->params();
    $params_r       = $self->_validateRequiredParams($params_r);
    $params_r       = $self->_validateOptionalParams($params_r);

    my @paramsLeft = @{ $params_r };
    if (@paramsLeft) {
        EBox::error("Unallowed parameters found in CGI request: @paramsLeft");
        throw EBox::Exceptions::External ( __('Your request could not be processed because it had some incorrect parameters'));
    }

    return 1;
}

sub _validateReferer
{
    my ($self) = @_;

    # Only check if the client sends params
    unless (@{$self->params()}) {
        return;
    }

    my $referer = $ENV{HTTP_REFERER};
    my $hostname = $ENV{HTTP_HOST};
    my $rshostname = $ENV{HTTP_HOST};

    # allow remoteservices proxy access
    # proxy is a valid subdomain of {domain}
    if (EBox::Global->modExists('remoteservices')) {
        my $rs = EBox::Global->modInstance('remoteservices');

        if ( $rs->eBoxSubscribed() ) {
            $rshostname = $rs->cloudDomain();
        }
    }
    if ($referer =~ m/^https:\/\/$hostname(:[0-9]*)?\// or
        $referer =~ m/^https:\/\/[^\/]*$rshostname(:[0-9]*)?\//) {
        return; # everything ok
    }
    throw EBox::Exceptions::External( __("Wrong HTTP referer detected, operation cancelled for security reasons"));
}

sub _validateRequiredParams
{
    my ($self, $params_r) = @_;

    my $matchResult_r = _matchParams($self->requiredParameters(), $params_r);
    my @requiresWithoutMatch = @{ $matchResult_r->{targetsWithoutMatch} };
    if (@requiresWithoutMatch) {
        EBox::error("Mandatory parameters not found in CGI request: @requiresWithoutMatch");
        throw EBox::Exceptions::External ( __('Your request could not be processed because it lacked some required parameters'));
    } else {
        my $allMatches = all  @{ $matchResult_r->{matches} };
        my @newParams = grep { $_ ne $allMatches } @{ $params_r} ;
        return \@newParams;
    }
}

sub _validateOptionalParams
{
    my ($self, $params_r) = @_;

    my $matchResult_r = _matchParams($self->optionalParameters(), $params_r);

    my $allMatches = all  @{ $matchResult_r->{matches} };
    my @newParams = grep { $_ ne $allMatches } @{ $params_r} ;
    return \@newParams;
}

sub _matchParams
{
    my ($targetParams_r, $actualParams_r) = @_;
    my @targets = @{ $targetParams_r };
    my @actualParams = @{ $actualParams_r};

    my @targetsWithoutMatch;
    my @matchedParams;
    foreach my $targetParam ( @targets ) {
        my $targetRe = qr/^$targetParam$/;
        my @matched = grep { $_ =~ $targetRe } @actualParams;
        if (@matched) {
            push @matchedParams, @matched;
        } else {
            push @targetsWithoutMatch, $targetParam;
        }
    }

    return { matches => \@matchedParams, targetsWithoutMatch => \@targetsWithoutMatch };
}

# Method: optionalParameters
#
#       Get the optional CGI parameter list. Any
#   parameter that match with this list may be present or absent
#   in the CGI parameters.
#
# Returns:
#
#       array ref - the list of matching parameters, it may be a names or
#       a regular expression, in the last case it cannot contain the
#       metacharacters ^ and $
#
sub optionalParameters
{
    return [];
}

# Method: requiredParameters
#
#   Get the required CGI parameter list. Any
#   parameter that match with this list must be present in the CGI
#   parameters.
#
# Returns:
#
#   array ref - the list of matching parameters, it may be a names
#   or a regular expression, in the last case it can not contain
#   the metacharacters ^ and $
#
sub requiredParameters
{
    return [];
}

# Method:  actuate
#
#  This method is the workhouse of the CGI it must be overriden by the different CGIs to achieve their objectives
sub actuate
{
}

# Method: masonParameters
#
#    This method must be overriden by the different child to return
#    the adequate template parameter for its state.
#
# Returns:
#  a  reference to a list which contains the names and values of the different mason parameters
#
sub masonParameters
{
    my ($self) = @_;

    if (exists $self->{params}) {
        return $self->{params};
    }

    return [];
}

# Method: upload
#
#  Upload a file from the client computer. The file is place in
#  the tmp directory (/tmp)
#
#
# Parameters:
#
#   uploadParam - String CGI parameter name which contains the path to the
#   file which will be uploaded. It is usually obtained from a HTML
#   file input
#
# Returns:
#
#   String - the path of the uploaded file
#
# Exceptions:
#
#   <EBox::Exceptions::Internal> - thrown if an error has happened
#   within the CGI or it is impossible to read the upload file or the
#   parameter does not pass on the request
#
#   <EBox::Exceptions::External> - thrown if there is no file to
#   upload or cannot create the temporally file
#
sub upload
{
    my ($self, $uploadParam) = @_;
    defined $uploadParam or throw EBox::Exceptions::MissingArgument();

    # upload parameter..
    my $uploadParamValue = $self->cgi->param($uploadParam);
    if (not defined $uploadParamValue) {
        if ($self->cgi->cgi_error) {
            throw EBox::Exceptions::Internal('Upload error: ' . $self->cgi->cgi_error);
        }
        throw EBox::Exceptions::Internal("The upload parameter $uploadParam does not "
                . 'pass on HTTP request');
    }

    # get upload contents file handle
    my $UPLOAD_FH = $self->cgi->upload($uploadParam);
    if (not $UPLOAD_FH) {
        throw EBox::Exceptions::External( __('Invalid uploaded file.'));
    }

    # destination file handle and path
    my ($FH, $filename) = tempfile("uploadXXXXX", DIR => EBox::Config::tmp());
    if (not $FH) {
        throw EBox::Exceptions::External( __('Cannot create a temporally file for the upload'));
    }

    try {
        #copy the uploaded data to file..
        my $readStatus;
        my $readData;
        my $readSize = 1024 * 8; # read in blocks of 8K
            while ($readStatus = read $UPLOAD_FH, $readData, $readSize) {
                print $FH $readData;
            }

        if (not defined $readStatus) {
            throw EBox::Exceptions::Internal("Error reading uploaded data: $!");
        }
    } otherwise {
        my $ex = shift;
        unlink $filename;
        $ex->throw();
    } finally {
        close $UPLOAD_FH;
        close $FH;
    };

    # return the created file in tmp
    return $filename;
}

# Method: setMenuNamespace
#
#   Set the menu namespace to help the menu code to find out
#   within which namespace this cgi is running.
#
#   Note that, this is useful only if you are using base CGIs
#   in modules different to ebox base. If you do not use this,
#   the namespace used will be the one the base cgi belongs to.
#
# Parameters:
#
#   (POSITIONAL)
#   namespace - string represeting the namespace in URL format. Example:
#           "EBox/Network"
#
sub setMenuNamespace
{
    my ($self, $namespace) = @_;

    $self->{'menuNamespace'} = $namespace;
}

# Method: menuNamespace
#
#   Return menu namespace to help the menu code to find out
#   within which namespace this cgi is running.
#
#   Note that, this is useful only if you are using base CGIs
#   in modules different to ebox base. If you do not use this,
#   the namespace used will be the one the base cgi belongs to.
#
# Returns:
#
#   namespace - string represeting the namespace in URL format. Example:
#           "EBox/Network"
#
sub menuNamespace
{
    my ($self) = @_;

    if (exists $self->{'menuNamespace'}) {
        return $self->{'menuNamespace'};
    } else {
        return $self->{'url'};
    }
}

sub JSONReply
{
    my ($self, $data_r) = @_;
    print $self->cgi()->header(-charset=>'utf-8',
                              -type => 'application/JSON',
                             );
    my $error = $self->{error};
    if ($error and not $data_r->{error}) {
        $data_r->{error} = $error;
    }
    print JSON::XS->new->encode($data_r);
}

1;
