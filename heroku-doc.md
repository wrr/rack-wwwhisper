To try wwwhisper-service, please send an email to
wwwhisper-service@mixedbit.org.

[wwwhisper](http://addons.heroku.com/wwwhisper) is an
[add-on](http://addons.heroku.com) for authorizing access to Heroku
applications.

The add-on lets you specify emails of users that are allowed to access
the application. [Persona](https://persona.org) is used to smoothly
and securely prove that a visitor owns an allowed email. Persona works
out of a box with any modern browser. It removes a need for
site-specific passwords, making passwords management a non-issue.

Integration with wwwhisper service is provided via Rack middleware
which can be used with any Rails or Rack based application. This
minimizes integration cost, there is no need to modify your
application code and explicitly call wwwhisper API.

A demo of wwwhisper authorized site is available at
https://wwwhisper-demo.herokuapp.com/. The site is configured to allow
everyone access. You can sign-in with your email or with any email in
the form `anything@mockmyid.com`.

## Provisioning the add-on

wwwhisper can be attached to a Heroku application via the CLI.

    :::term
    $ heroku addons:add wwwhisper --admin=[put your email here]

`--admin` is a required parameter that instructs wwwhisper to grant you
access to the application. Later you can use the wwwhisper admin site
to grant access to others.

Once the add-on has been added a `WWWHISPER_URL` setting will be
available in the app configuration and will contain the URL to
communicate with the wwwhisper service. This can be confirmed using the
`heroku config:get` command.

    :::term
    $ heroku config:get WWWHISPER_URL
    https://user:password@domain


## Using with Ruby.

All Ruby applications need to add the following entry into their
`Gemfile`.

    :::ruby
    gem 'rack-wwwhisper', '~> 1.0'

And then update application dependencies with bundler.

    :::term
    $ bundle install

###Enabling wwwhisper middleware in Rails.

To enable wwwhisper middleware for Rails application add a following
line to `config/environments/production.rb`.

    :::ruby
    config.middleware.insert_after "Rack::Lock", "Rack::WWWhisper"

You can consult [a
commit](https://github.com/wrr/typo/commit/70acd99924dd59fab45efccc426233a2d9ee4f7e)
that enabled wwwhisper for a Rails based Typo blog.

###Enabling wwwhisper middleware for other Rack based applications.

To enable wwwhisper middleware for other Rack based applications add
following two lines to the `config.ru`:

    require 'rack/wwwhisper'
    use Rack::WWWhisper

You can consult [a
commit](https://github.com/wrr/heroku-sinatra-app/commit/f152a4370d6b1c881f8dd60a91a3f050a8c6389b)
that enabled wwwhisper for a simple Sinatra application.

## Where to place wwwhisper middleware in the Rack middleware chain?

Order of Rack middlewares matters. Authentication should be
performed early, before any middleware that produces sensitive
responses is invoked.

wwwhisper by default inserts an iframe to HTML responses. The iframe
contains an email of currently logged in user and a logout button. If
Rack is configured to compress responses, compression middleware
should be put before wwwhisper, otherwise iframe won't be injected.

## Push the configuration and test the authorization.

    :::term
    $ git commit -m "Enable wwwhisper authorization" -a
    $ git push heroku master

Visit `https://yourapp-name.herokuapp.com/` you should see a login
page. sign-in with an email that you have passed to `heroku addons:add
wwwhisper --admin=` command. Visit
`https://yourapp-name.herokuapp.com/wwwhisper/admin/` to specify which
locations can be accessed by which visitors and which should be open
to everyone.

## Local setup

It is usually convenient to disable wwwhisper authorization for a
local development environment. If your application uses separate
config files for development (for example
`config/environments/development.rb` in case of Rails) you don't need
to do anything, otherwise you need to set `WWWHISPER_DISABLE=1`
environment variable.

If you use [Foreman](config-vars#local_setup) to start a local server,
execute a following command in the application directory.

    :::term
    $ echo WWWHISPER_DISABLE=1 >> .env

If you don't use Foreman, execute.

    :::term
    $ export WWWHISPER_DISABLE=1


## Removing the add-on

wwwhisper can be removed via the CLI.

<div class="warning" markdown="1">This will destroy all associated data and cannot be undone!</div>

    :::term
    $ heroku addons:remove wwwhisper

## A privacy note

wwwhisper service stores emails of users allowed to access your
application. The emails are used ONLY to authorize access to the
application. The service does not sent any messages to the email
addresses, emails are not disclosed to third parties.

wwwhisper does not store information which users accessed which
locations of your application.

## Final remarks

For maximum security access wwwhisper protected applications over HTTPS.

Your application can retrieve an email of authenticated user from a Rack
environment variable `REMOTE_USER`.

wwwhisper authorizes access only to content served by the Heroku
application. If you put sensitive content on external servers that do
not require authorization (for example Amazon CloudFront), wwwhisper
won't be able to restrict access to such content.

wwwhisper is open source, see [the project repository]
(https://github.com/wrr/wwwhisper) for a detailed explanation how it
works.

## Support

wwwhisper support and runtime issues should be submitted via one of
the [Heroku Support channels](support-channels). Any non-support
related issues or product feedback is welcome at
[[wwwhisper-service@mixedbit.org]]. Issues and feature requests
related to wwwhisper project in general and not limited to the add-on
can be also reported via [github](https://github.com/wrr/wwwhisper/issues).

