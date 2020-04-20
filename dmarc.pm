#
# Author: Giovanni Bechis <gbechis@apache.org>
# Copyright 2020 Giovanni Bechis
#
# <@LICENSE>
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to you under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at:
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# </@LICENSE>
#

=head1 NAME

Mail::SpamAssassin::Plugin::Dmarc - check Dmarc policy

=head1 SYNOPSIS

  loadplugin Mail::SpamAssassin::Plugin::Dmarc

  ifplugin Mail::SpamAssassin::Plugin::Dmarc
    header DMARC_REJECT eval:check_dmarc_reject()
    describe DMARC_REJECT Dmarc reject policy
  endif

=head1 DESCRIPTION

This plugin checks if emails matches Dmarc policy.

=cut

package Mail::SpamAssassin::Plugin::Dmarc;

use strict;
use warnings;
use re 'taint';

my $VERSION = 0.1;

use Mail::SpamAssassin;
use Mail::SpamAssassin::Plugin;

our @ISA = qw(Mail::SpamAssassin::Plugin);

use constant HAS_DMARC => eval { require Mail::DMARC::PurePerl; };

BEGIN
{
    eval{
      import Mail::DMARC::PurePerl
    };
}

sub dbg { Mail::SpamAssassin::Plugin::dbg ("Dmarc: @_"); }

# XXX copied from "FromNameSpoof" plugin, put into util ?
sub uri_to_domain {
  my ($self, $domain) = @_;

  return unless defined $domain;

  if ($Mail::SpamAssassin::VERSION <= 3.004000) {
    Mail::SpamAssassin::Util::uri_to_domain($domain);
  } else {
    $self->{main}->{registryboundaries}->uri_to_domain($domain);
  }
}

sub new {
    my ($class, $mailsa) = @_;

    $class = ref($class) || $class;
    my $self = $class->SUPER::new($mailsa);
    bless ($self, $class);

    $self->set_config($mailsa->{conf});
    $self->register_eval_rule("check_dmarc_reject");
    $self->register_eval_rule("check_dmarc_quarantine");
    $self->register_eval_rule("check_dmarc_none");

    return $self;
}

sub set_config {
}

sub check_dmarc_reject {
  my ($self,$pms,$name) = @_;

  my @tags = ('DKIMCHECKDONE');

  $pms->action_depends_on_tags(\@tags,
      sub { my($pms, @args) = @_;
        $self->_check_dmarc(@_);
        if(($self->{dmarc_result} eq 'fail') and ($self->{dmarc_policy} eq 'reject')) {
          $pms->got_hit($pms->get_current_eval_rule_name(), "");
          return 1;
        }
      }
  );
  return 0;
}

sub check_dmarc_quarantine {
  my ($self,$pms,$name) = @_;

  my @tags = ('DKIMCHECKDONE');

  $pms->action_depends_on_tags(\@tags,
      sub { my($pms, @args) = @_;
        $self->_check_dmarc(@_);
        if(($self->{dmarc_result} eq 'fail') and ($self->{dmarc_policy} eq 'quarantine')) {
          $pms->got_hit($pms->get_current_eval_rule_name(), "");
          return 1;
        }
      }
  );
  return 0;
}

sub check_dmarc_none {
  my ($self,$pms,$name) = @_;

  my @tags = ('DKIMCHECKDONE');

  $pms->action_depends_on_tags(\@tags,
      sub { my($pms, @args) = @_;
        $self->_check_dmarc(@_);
        if(($self->{dmarc_result} eq 'fail') and ($self->{dmarc_policy} eq 'none')) {
          $pms->got_hit($pms->get_current_eval_rule_name(), "");
          return 1;
        }
      }
  );
  return 0;
}

sub _check_dmarc {
  my ($self,$pms,$name) = @_;
  my $spf_status = 'none';
  my $spf_helo_status = 'none';
  my ($dmarc, $lasthop, $result);

  if((defined $self->{dmarc_checked}) and ($self->{dmarc_checked} eq 1)) {
    return;
  }
  $dmarc = Mail::DMARC::PurePerl->new();
  $lasthop = $pms->{relays_external}->[0];
  return if (not defined $lasthop->{ip});

  # XXX handle all spf result codes
  $spf_status = 'pass' if ($pms->{spf_pass} eq 1);
  $spf_status = 'fail' if ($pms->{spf_fail} eq 1);
  $spf_helo_status = 'pass' if ($pms->{spf_helo_pass} eq 1);
  $spf_helo_status = 'fail' if ($pms->{spf_helo_fail} eq 1);

  $dmarc->source_ip($lasthop->{ip});
  $dmarc->envelope_to($self->uri_to_domain($pms->get('To:addr')));
  $dmarc->envelope_from($self->uri_to_domain($lasthop->{envfrom}));
  $dmarc->header_from($self->uri_to_domain($pms->get('From:addr')));
  $dmarc->dkim($pms->{dkim_verifier});
  $dmarc->spf([
    {
        scope  => 'mfrom',
        domain => "$self->uri_to_domain($pms->{spf_sender})",
        result => "$spf_status",
    },
    {
        scope  => 'helo',
        domain => "$lasthop->{lc_helo}",
        result => "$spf_helo_status",
    },
  ]);
  $result = $dmarc->validate();

  # use Data::Dumper
  # dbg("Result: " . Dumper $result);
  $self->{dmarc_result} = $result->result;
  $self->{dmarc_policy} = $result->published->p;
  $self->{dmarc_checked} = 1;
}

1;
