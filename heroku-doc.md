Work in progress. If you want to try wwwhisper-service, please send an
email to wwwhisper-service@mixedbit.org.

[wwwhisper](http://addons.heroku.com/wwwhisper) is an
[add-on](http://addons.heroku.com) for authorizing access to Heroku
applications.

wwwhisper lets you specify emails of users that are allowed to access
the application. It uses [Persona](https://persona.org) to smoothly
and securely prove that a visitor owns an allowed email. Persona
removes a need for site-specific passwords, making passwords
management a non-issue.

Integration with wwwhisper service is provided via Rack middleware
which can be used with any Rails or Rack based application. This
minimizes integration cost, there is no need to modify your
application code and explicitly call wwwhisper API.


## Provisioning the add-on

wwwhisper can be attached to a Heroku application via the CLI.

    :::term
    $ heroku addons:add wwwhisper --admin=[put your email here]

`--admin` is a required parameter that instruct wwwhisper to grant you
access to the application. Later you can use the wwwhisper admin site
to grant access to other users.

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

It is convenient to disable wwwhisper authorization for development
environment. If you use [Foreman](config-vars#local_setup) to start a
local server, you can disable wwwhisper by executing following command
in the application directory.

    :::term
    $ echo WWWHISPER_DISABLE=1 >> .env

If you don't use Foreman, you can execute.

    :::term
    $ export WWWHISPER_DISABLE=1


## Using with Rails 3.x

Ruby on Rails applications need to add the following entry into
their `Gemfile`.

    :::ruby
    gem 'wwwhisper-rack'

Update application dependencies with bundler.

    :::term
    $ bundle install

Add following two lines to the `config.ru`:

    require 'rack/wwwhisper'
    # ...
    use Rack::WWWhisper

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