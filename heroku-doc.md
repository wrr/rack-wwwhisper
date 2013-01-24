Work in progress. If you want to try wwwhisper-service, please send an
email to wwwhisper-service@mixedbit.org.

[wwwhisper](http://addons.heroku.com/wwwhisper) is an
[add-on](http://addons.heroku.com) for authorizing access to Heroku
applications.

wwwhisper lets you specify emails of users that are allowed to access
the application. It uses [Persona](https://persona.org) to smoothly
and securely prove that a visitor owns one of allowed emails. Persona
works out of a box with any modern browser. It removes a need for
site-specific passwords, making passwords management a non-issue.

Integration with wwwhisper service is provided via Rack middleware
which can be used with any Rails or Rack based application. This
minimizes integration cost, there is no need to modify your
application code and explicitly call wwwhisper API.

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

After installing wwwhisper the application should be configured to
fully integrate with the add-on.

## Local setup

### Environment setup

It is usually convenient to disable wwwhisper authorization for a local
development environment. If you use [Foreman](config-vars#local_setup)
to start a local server, you can disable wwwhisper by executing
following command in the application directory.

    :::term
    $ echo WWWHISPER_DISABLE=1 >> .env

If you don't use Foreman, you can execute.

    :::term
    $ export WWWHISPER_DISABLE=1


## Using with Ruby.

Ruby applications need to add the following entry into their
`Gemfile`.

    :::ruby
    gem 'wwwhisper-rack'

Update application dependencies with bundler.

    :::term
    $ bundle install

###Enabling wwwhisper middleware in Rails.

###Enabling wwwhisper middleware in other Rack based applications.

Add following two lines to the `config.ru`:

    require 'rack/wwwhisper'
    # ...
    use Rack::WWWhisper

### Where to place wwwhisper middleware in the Rack middleware chain?

Order of Rack middlewares matters. Authentication should be
performed early, before any middleware that produces sensitive
responses is invoked.

wwwhisper by default inserts an iframe to HTML responses. The iframe
contains an email of currently logged in user and a logout button. If
Rack is configured to compress responses, compression middleware
should be put before wwwhisper, otherwise iframe won't be injected.

## Dashboard

To access the wwwhisper admin interface visit
'https://yourapp-name.herokuapp.com/wwwhisper/admin` and sign-in with
an email that you have passed `heroku addons:add wwwhisper --admin=`
command. The admin interface allows to specify which locations can be
accessed by which visitors and which should be open to everyone. It
also allows to add additional admin users.

## Removing the add-on

wwwhisper can be removed via the CLI.

<div class="warning" markdown="1">This will destroy all associated data and cannot be undone!</div>

    :::term
    $ heroku addons:remove wwwhisper


## Support

wwwhisper support and runtime issues should be submitted via one of
the [Heroku Support channels](support-channels). Any non-support
related issues or product feedback is welcome at
[[wwwhisper-service@mixedbit.org]]. Issues and feature requests
related to wwwhisper project in general and not limited to the add-on
can be also reported via [github](https://github.com/wrr/wwwhisper/issues).