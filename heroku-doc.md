[wwwhisper](http://addons.heroku.com/wwwhisper) is an
[add-on](http://addons.heroku.com) for authorizing access to
Rails or Rack based Heroku applications.

The add-on provides a web interface to specify emails of users that
are allowed to access your application. Each visitor is presented with
a login prompt, [Persona](https://persona.org) is used to smoothly
and securely prove that a visitor owns an allowed email. Persona works
out of a box with any modern browser. It removes the need for
site-specific passwords, making passwords management a non-issue for
you.

Integration with wwwhisper service is provided via Rack middleware
This minimizes integration cost, there is no need to modify your
application code and explicitly call wwwhisper API.

You can visit [a demo site](https://wwwhisper-demo.herokuapp.com/)
authorized by the wwwhisper add-on. The site is configured to allow
everyone access,  sign-in with your email or with any email in
the form `anything@mockmyid.com`.

## Provisioning the add-on

wwwhisper can be attached to a Heroku application via the CLI.

    :::term
    $ heroku addons:add wwwhisper [--admin=your_email]

`--admin` is an optional parameter that specifies who should be
allowed to initially access the application. If `--admin` is not
given, or if the add-on is provisioned via Heroku web UI, your Heroku
application owner email is used. Later you can use the wwwhisper admin
site to grant access to others.

Once the add-on has been added a `WWWHISPER_URL` setting will be
available in the app configuration and will contain the URL to
communicate with the wwwhisper service. This can be confirmed using the
`heroku config:get` command.

    :::term
    $ heroku config:get WWWHISPER_URL
    https://user:password@domain


## Using with Ruby on Rails or other Rack based applications

All Ruby applications need to add the following entry into their
`Gemfile`.

    :::ruby
    gem 'rack-wwwhisper', '~> 1.0'

And then update application dependencies with bundler.

    :::term
    $ bundle install

###Enabling wwwhisper middleware for a Rails application

For a Rails application put the following line at the end of
`config/environments/production.rb`.

    :::ruby
    config.middleware.insert 0, "Rack::WWWhisper"

The line makes wwwhisper the first middleware in the Rack middleware
chain. You can consult [a
commit](https://github.com/wrr/typo/commit/6949e4f65aa5b39e1d36f0fefe21a7a360f83bf4)
that enabled wwwhisper for a Rails based Typo blog.

###Enabling wwwhisper middleware for other Rack based application

For other Rack based applications add the following two lines to the
`config.ru`.

    :::ruby
    require 'rack/wwwhisper'
    use Rack::WWWhisper

You can consult [a
commit](https://github.com/wrr/heroku-sinatra-app/commit/f152a4370d6b1c881f8dd60a91a3f050a8c6389b)
that enabled wwwhisper for a Sinatra application.

### Rack middleware order

Order of Rack middleware matters. Authorization should be performed
early, before any middleware that produces sensitive responses is
invoked. Rails allows to check middleware order with a command.

    :::term
    RAILS_ENV=production; foreman run rake middleware

wwwhisper by default inserts an iframe to HTML responses. The iframe
contains an email of a currently logged in user and a logout
button. If Rack is configured to compress responses, compression
middleware should be put before wwwhisper, otherwise the iframe won't
be inserted.

### Push the configuration and test the authorization

    :::term
    $ git commit -m "Enable wwwhisper authorization" -a
    $ git push heroku master

Visit `https://yourapp-name.herokuapp.com/` you should be presented
with a login page. Sign-in with your email. Visit
`https://yourapp-name.herokuapp.com/wwwhisper/admin/` to specify which
locations can be accessed by which visitors and which (if any) should
be open to everyone.

### Local setup

#### Disable wwwhisper locally

It is usually convenient to disable wwwhisper authorization for a
local development environment. If your application uses a separate
config file for development (for example
`config/environments/development.rb` in case of Rails) you don't need
to do anything, otherwise you need to set `WWWHISPER_DISABLE=1`
environment variable.

If you use [Foreman](config-vars#local_setup) to start a local server,
execute the following command in the application directory.

    :::term
    $ echo WWWHISPER_DISABLE=1 >> .env

If you don't use Foreman, execute.

    :::term
    $ export WWWHISPER_DISABLE=1

#### Use wwwhisper locally

If you want to use the wwwhisper service locally, copy WWWHISPER_URL
variable from the Heroku config. If you use Foreman, execute.

    :::term
    $ echo WWWHISPER_URL=`heroku config:get WWWHISPER_URL` >> .env

<p class="warning" markdown="1"> Credentials and other sensitive
configuration values should not be committed to source-control. In Git
exclude the .env file with: `echo .env >> .gitignore`. </p>

If you don't use Foreman, execute.

    :::term
    $ export WWWHISPER_URL=`heroku config:get WWWHISPER_URL`

## Removing the add-on

wwwhisper can be removed via the CLI.

<div class="warning" markdown="1">This will destroy all associated data and cannot be undone!</div>

    :::term
    $ heroku addons:remove wwwhisper

## A privacy note

wwwhisper service stores emails of users allowed to access your
application. The emails are used ONLY to authorize access to the
application. The service does not send any messages to the email
addresses, emails are not disclosed to third parties.

wwwhisper does not store information which users accessed which
locations of your application.

## Support

wwwhisper support and runtime issues should be submitted via one of
the [Heroku Support channels](support-channels). Any non-support
related issues or product feedback is welcome at
wwwhisper-service@mixedbit.org. Issues and feature requests
related to wwwhisper project in general and not limited to the add-on
can be also reported via [github](https://github.com/wrr/wwwhisper).

## Final remarks

* For maximum security access wwwhisper protected applications over HTTPS.
* Your application can retrieve an email of authenticated user from a
  Rack environment variable `REMOTE_USER`.
* wwwhisper authorizes access to content served by a Heroku
  application. If you put sensitive content on external servers that do
  not require authorization (for example public Amazon S3 bucket), wwwhisper
  won't be able to restrict access to such content.
* wwwhisper is open source, see
  [the project repository] (https://github.com/wrr/wwwhisper)
  for a detailed explanation of how it works.
