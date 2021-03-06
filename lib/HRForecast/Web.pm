package HRForecast::Web;

use strict;
use warnings;
use utf8;
use Kossy;
use HTTP::Date;
use Time::Piece;
use HRForecast::Data;
use HRForecast::Calculator;
use Log::Minimal;
use JSON qw//;

my $JSON = JSON->new()->ascii(1);
sub encode_json {
    $JSON->encode(shift);
}

sub data {
    my $self = shift;
    $self->{__data} ||= HRForecast::Data->new();
    $self->{__data};
}

sub calc_term {
    my $self = shift;
    my %args = @_;

    my $term   = $args{t};
    my $from   = $args{from};
    my $to     = $args{to};
    my $offset = $args{offset};
    my $period = $args{period};

    if ( $term eq 'w' ) {
        $from = time - 86400 * 10;
        $to = time;
    }
    elsif ( $term eq 'm' ) {
        $from = time - 86400 * 40;
        $to = time;
    }
    elsif ( $term eq 'y' ) {
        $from = time - 86400 * 400;
        $to = time;
    }
    elsif ( $term eq 'range' ) {
        $to = time - $offset;
        $from = $to - $period;
    }
    else {
        $from = HTTP::Date::str2time($from);
        $to = HTTP::Date::str2time($to);
    }
    $from = localtime($from - ($from % $self->data->round_interval));
    $to = localtime($to - ($to % $self->data->round_interval));
    return ($from,$to);
}

filter 'sidebar' => sub {
    my $app = shift;
    sub {
        my ( $self, $c )  = @_;
        my $services = $self->data->get_services();
        my @services;
        for my $service ( @$services ) {
            my $sections = $self->data->get_sections($service);
            my @sections;
            for my $section ( @$sections ) {
                push @sections, {
                    active => 
                        $c->args->{service_name} && $c->args->{service_name} eq $service &&
                            $c->args->{section_name} && $c->args->{section_name} eq $section ? 1 : 0,
                    name => $section
                };
            }
            my $dot_escaped = $service;
            $dot_escaped =~ s/\./__2E__/g;
            push @services , {
                name => $service,
                collapse => $c->req->cookies->{'sidebar_collapse_' . $dot_escaped},
                sections => \@sections,
            };
        }
        $c->stash->{services} = \@services;
        $app->($self,$c);
    }
};


filter 'get_metrics' => sub {
    my $app = shift;
    sub {
        my ($self, $c) = @_;
        my $row = $self->data->get(
            $c->args->{service_name}, $c->args->{section_name}, $c->args->{graph_name},
        );
        $c->halt(404) unless $row;
        $c->stash->{metrics} = $row;
        $app->($self,$c);
    }
};

filter 'get_complex' => sub {
    my $app = shift;
    sub {
        my ($self, $c) = @_;
        my $row = $self->data->get_complex(
            $c->args->{service_name}, $c->args->{section_name}, $c->args->{graph_name},
        );
        $c->halt(404) unless $row;
        $c->stash->{metrics} = $row;
        $app->($self,$c);
    }
};

filter 'unset_frame_option' => sub {
    my $app = shift;
    sub {
        my ($self, $c) = @_;
        $c->res->headers->remove_header('X-Frame-Options');
        $app->($self,$c);
    }
};

filter 'display_table' => sub {
    my $app = shift;
    sub {
        my ($self, $c) = @_;
        $c->stash->{display_table} = 1;
        $app->($self,$c);
    }
};

get '/' => [qw/sidebar/] => sub {
    my ( $self, $c )  = @_;
    $c->render('index.tx', {});
};

get '/json' => [qw/sidebar/] => sub {
    my ( $self, $c )  = @_;
    $c->render_json({
        error => 0,
        services => $c->stash->{services},
    });
};

get '/docs' => [qw/sidebar/] => sub {
    my ( $self, $c )  = @_;
    $c->render('docs.tx',{calculations => HRForecast::Calculator::CALCULATIONS});
};

my $metrics_validator = [
    't' => {
        default => 'm',
        rule => [
            [['CHOICE',qw/w m y c range/],'invalid browse term'],
        ],
    },
    'from' => {
        default => sub { localtime(time-86400*35)->strftime('%Y/%m/%d %T') },
        rule => [
            [sub{ HTTP::Date::str2time($_[1]) }, 'invalid From datetime'],
        ],
    },
    'period' => {
        default => 0,
        rule => [
            ['UINT', 'invalid interval'],
        ],
    },
    'offset' => {
        default => 0,
        rule => [
            ['UINT', 'invalid offset'],
        ],
    },
    'to' => {
        default => sub { localtime()->strftime('%Y/%m/%d %T') },
        rule => [
            [sub{ HTTP::Date::str2time($_[1]) }, 'invalid To datetime'],
        ],
    },
    'd' => {
        default => 0,
        rule => [
            [['CHOICE',qw/1 0/],'invalid download flag'],
        ],
    },
    'stack' => {
        default => 0,
        rule => [
            [['CHOICE',qw/1 0/],'invalid stack flag'],
        ],
    },
    'graphheader' => {
        default => 1,
        rule => [
            [['CHOICE',qw/1 0/],'invalid graphheader flag'],
        ],
    },
    'graphlabel' => {
        default => 1,
        rule => [
            [['CHOICE',qw/1 0/],'invalid graphlabel flag'],
        ],
    },
    'calculation' => {
        default => '',
        rule => [
            [['CHOICE', map { $_->{function} } @{HRForecast::Calculator::CALCULATIONS()} ],'invalid calculation'],
        ],
    },
];

sub _build_metrics_params {
    my $result = shift;

    my $term = $result->valid('t');
    my @params;
    push @params, 't', $term;
    if ($term eq 'range') {
        push @params, $_ => $result->valid($_) for qw/period offset/;
    }
    elsif ($term eq 'c') {
        push @params, $_ => $result->valid($_) for qw/from to/;
    }

    my $calculation = $result->valid('calculation');
    if ($calculation && ($calculation ne '')) {
        push @params, 'calculation', $calculation;
    }

    \@params;
}

sub create_merge_params {
    my $array_ref = shift;

    return sub {
        my $hash_ref = shift;
        my %params_hash = (@$array_ref, %$hash_ref);

        while (my ($key, $value) = each(%params_hash)){
            if ($value eq '') {
                delete $params_hash{$key};
            }
        }

        my @params_array = %params_hash;

        return \@params_array;
    }
};

get '/list/:service_name/:section_name' => [qw/sidebar/] => sub {
    my ( $self, $c )  = @_;
    my $result = $c->req->validator($metrics_validator);
    my $rows = $self->data->get_metricses(
        $c->args->{service_name}, $c->args->{section_name}
    );
    my ($from ,$to) = $self->calc_term( map {($_ =>  $result->valid($_))} qw/t from to period offset/);
    my $metrics_params = _build_metrics_params($result);
    $c->render('list.tx',{ 
        metricses => $rows,
        valid => $result,
        metrics_params => $metrics_params,
        date_window => encode_json([$from->strftime('%Y/%m/%d %T'),
                                    $to->strftime('%Y/%m/%d %T')]),
        calculations => HRForecast::Calculator::CALCULATIONS,
        merge_params => HRForecast::Web::create_merge_params($metrics_params),
    });
};

get '/json/:service_name/:section_name' => sub {
    my ( $self, $c )  = @_;
    my $rows = $self->data->get_metricses(
        $c->args->{service_name}, $c->args->{section_name}
    );
    $c->render_json({
        error => 0,
        metricses => $rows
    });
};


get '/view/:service_name/:section_name/:graph_name' => [qw/sidebar get_metrics/] => sub {
    my ( $self, $c )  = @_;
    my $result = $c->req->validator($metrics_validator);
    my ($from ,$to) = $self->calc_term( map {($_ =>  $result->valid($_))} qw/t from to period offset/);
    my $metrics_params = _build_metrics_params($result);
    $c->render('list.tx', {
        metricses => [$c->stash->{metrics}],
        valid => $result,
        metrics_params => $metrics_params,
        date_window => encode_json([$from->strftime('%Y/%m/%d %T'),
                                    $to->strftime('%Y/%m/%d %T')]),
        calculations => HRForecast::Calculator::CALCULATIONS,
        merge_params => HRForecast::Web::create_merge_params($metrics_params),
    });
};

get '/json/:service_name/:section_name/:graph_name' => [qw/get_metrics/] => sub {
    my ( $self, $c )  = @_;
    $c->render_json({
        error => 0,
        metricses => [$c->stash->{metrics}],
    });
};


get '/view_complex/:service_name/:section_name/:graph_name' => [qw/sidebar get_complex/] => sub {
    my ( $self, $c )  = @_;
    my $result = $c->req->validator($metrics_validator);
    my ($from ,$to) = $self->calc_term( map {($_ =>  $result->valid($_))} qw/t from to period offset/);
    my $metrics_params = _build_metrics_params($result);
    $c->render('list.tx', {
        metricses => [$c->stash->{metrics}],
        valid => $result,
        metrics_params => $metrics_params,
        date_window => encode_json([$from->strftime('%Y/%m/%d %T'),
                                    $to->strftime('%Y/%m/%d %T')]),
        calculations => HRForecast::Calculator::CALCULATIONS,
        merge_params => HRForecast::Web::create_merge_params($metrics_params),
    });
};

get '/json_complex/:service_name/:section_name/:graph_name' => [qw/get_complex/] => sub {
    my ( $self, $c )  = @_;
    $c->render_json({
        error => 0,
        metricses => [$c->stash->{metrics}],
    });
};

get '/ifr/:service_name/:section_name/:graph_name' => [qw/unset_frame_option get_metrics/] => sub {
    my ( $self, $c )  = @_;
    my $result = $c->req->validator($metrics_validator);
    my ($from ,$to) = $self->calc_term( map {($_ =>  $result->valid($_))} qw/t from to period offset/);
    my $metrics_params = _build_metrics_params($result);
    $c->render('ifr.tx', {
        metrics => $c->stash->{metrics},
        valid => $result,
        metrics_params => $metrics_params,
        date_window => encode_json([$from->strftime('%Y/%m/%d %T'),
                                    $to->strftime('%Y/%m/%d %T')]),
        calculations => HRForecast::Calculator::CALCULATIONS,
        merge_params => HRForecast::Web::create_merge_params($metrics_params),
    });
};

get '/ifr_complex/:service_name/:section_name/:graph_name' => [qw/unset_frame_option get_complex/] => sub {
    my ( $self, $c )  = @_;
    my $result = $c->req->validator($metrics_validator);
    my ($from ,$to) = $self->calc_term( map {($_ =>  $result->valid($_))} qw/t from to period offset/);
    my $metrics_params = _build_metrics_params($result);
    $c->render('ifr_complex.tx', {
        metrics => $c->stash->{metrics},
        valid => $result,
        metrics_params => $metrics_params,
        date_window => encode_json([$from->strftime('%Y/%m/%d %T'),
                                    $to->strftime('%Y/%m/%d %T')]),
        calculations => HRForecast::Calculator::CALCULATIONS,
        merge_params => HRForecast::Web::create_merge_params($metrics_params),
    });
};

get '/ifr/preview/' => [qw/unset_frame_option/] => sub {
    my ( $self, $c )  = @_;
    $c->render('pifr_dummy.tx');
};

get '/ifr/preview/:complex' => [qw/unset_frame_option/] => sub {
    my ( $self, $c )  = @_;
    my $result = $c->req->validator($metrics_validator);
    my ($from ,$to) = $self->calc_term( map {($_ =>  $result->valid($_))} qw/t from to period offset/);

    my @complex = split /:/, $c->args->{complex};
    my @colors;
    my @metricses;
    for my $id ( @complex ) {
        my $data = $self->data->get_by_id($id);
        push @metricses, $data;
        push @colors, $data ? $data->{color} : '#cccccc';
    }

    $c->render('pifr.tx', {
        metricses => [@metricses],
        complex => $c->args->{complex},
        valid => $result,
        metrics_params => _build_metrics_params($result),
        colors => encode_json(\@colors),
        date_window => encode_json([$from->strftime('%Y/%m/%d %T'),
                                    $to->strftime('%Y/%m/%d %T')]),
    });
};

get '/edit/:service_name/:section_name/:graph_name' => [qw/sidebar get_metrics/] => sub {
    my ( $self, $c )  = @_;
    $c->render('edit.tx');
};

post '/edit/:service_name/:section_name/:graph_name' => [qw/get_metrics/] => sub {
    my ( $self, $c )  = @_;
    my $check_uniq = sub {
        my ($req,$val) = @_;
        my $service = $req->param('service_name');
        my $section = $req->param('section_name');
        my $graph = $req->param('graph_name');
        $service = '' if !defined $service;
        $section = '' if !defined $section;
        $graph = '' if !defined $graph;
        my $row = $self->data->get($service,$section,$graph);
        return 1 if $row && $row->{id} == $c->stash->{metrics}->{id};
        return 1 if !$row;
        return;
    };
    my $result = $c->req->validator([
        'service_name' => {
            rule => [
                ['NOT_NULL', 'サービス名がありません'],
            ],
        },
        'section_name' => {
            rule => [
                ['NOT_NULL', 'セクション名がありません'],
            ],
        },
        'graph_name' => {
            rule => [
                ['NOT_NULL', 'グラフ名がありません'],
                [$check_uniq,'同じ名前のグラフがあります'],
            ],
        },
        'description' => {
            default => '',
            rule => [],
        },
        'sort' => {
            rule => [
                ['NOT_NULL', '値がありません'],
                [['CHOICE',0..19], '値が正しくありません'],
            ],
        },
        'color' => {
            rule => [
                ['NOT_NULL', '正しくありません'],
                [sub{ $_[1] =~ m!^#[0-9A-F]{6}$!i }, '#000000の形式で入力してください'],
            ],
        },
    ]);
    if ( $result->has_error ) {
        my $res = $c->render_json({
            error => 1,
            messages => $result->errors
        });
        return $res;
    }

    $self->data->update_metrics(
        $c->stash->{metrics}->{id},
        $result->valid->as_hashref
    );

    my $row = $self->data->get(
        $c->args->{service_name}, $c->args->{section_name}, $c->args->{graph_name},
    );

    $c->render_json({
        error => 0,
        metricses => [$row],
        location => $c->req->uri_for(
            '/list/'.$result->valid('service_name').'/'.$result->valid('section_name'))->as_string,
    });
};

post '/delete/:service_name/:section_name/:graph_name' => [qw/get_metrics/] => sub {
    my ( $self, $c )  = @_;
    $self->data->delete_metrics(
        $c->stash->{metrics}->{id},
    );
    $c->render_json({
        error => 0,
        location => $c->req->uri_for(
            '/list/'.$c->args->{service_name}.'/'.$c->args->{section_name})->as_string,
    });
};

get '/add_complex' => [qw/sidebar/] => sub {
    my ( $self, $c )  = @_;
    my $all_metrics_names = $self->data->get_all_metrics_name();
    $c->render('add_complex.tx', { all_metrics_names => $all_metrics_names } );
};

sub check_uniq_complex {
    my ($self,$id) = @_;
    sub {
        my ($req,$val) = @_;
        my $service = $req->param('service_name');
        my $section = $req->param('section_name');
        my $graph = $req->param('graph_name');
        $service = '' if !defined $service;
        $section = '' if !defined $section;
        $graph = '' if !defined $graph;
        my $row = $self->data->get_complex($service,$section,$graph);
        if ($id) {
            return 1 if $row && $row->{id} == $id;
        }
        return 1 if !$row;
        return;
    };
}

post '/add_complex' => sub {
    my ( $self, $c )  = @_;
    my $result = $c->req->validator([
        'service_name' => {
            rule => [
                ['NOT_NULL', 'サービス名がありません'],
            ],
        },
        'section_name' => {
            rule => [
                ['NOT_NULL', 'セクション名がありません'],
            ],
        },
        'graph_name' => {
            rule => [
                ['NOT_NULL', 'グラフ名がありません'],
                [$self->check_uniq_complex,'同じ名前のグラフがあります'],
            ],
        },
        'description' => {
            default => '',
            rule => [],
        },
        'stack' => {
            rule => [
                ['NOT_NULL', 'スタックの値がありません'],
                [['CHOICE',0,1], 'スタックの値が正しくありません'],
            ],
        },
        'sort' => {
            rule => [
                ['NOT_NULL', 'ソートの値がありません'],
                [['CHOICE',0..19], 'ソートの値が正しくありません'],
            ],
        },
        '@path-data' => {
            rule => [
                [['@SELECTED_NUM',1,100], 'データは100件までにしてください'],
                ['NOT_NULL','データが正しくありません'],
                ['NATURAL', 'データが正しくありません'],
            ],
        },
    ]);
    if ( $result->has_error ) {
        my $res = $c->render_json({
            error => 1,
            messages => $result->errors
        });
        return $res;
    }

    $self->data->create_complex(
        $result->valid('service_name'),$result->valid('section_name'),$result->valid('graph_name'),
        $result->valid->mixed
    );

    my $row = $self->data->get_complex(
        $c->args->{service_name}, $c->args->{section_name}, $c->args->{graph_name},
    );

    $c->render_json({
        error => 0,
        metricses => [$row],
        location => $c->req->uri_for('/list/'.$result->valid('service_name').'/'.$result->valid('section_name'))->as_string,
    });
};

get '/edit_complex/:service_name/:section_name/:graph_name' => [qw/sidebar get_complex/] => sub {
    my ( $self, $c )  = @_;
    my $all_metrics_names = $self->data->get_all_metrics_name();
    $c->render('edit_complex.tx', { all_metrics_names => $all_metrics_names } );
};

post '/edit_complex/:service_name/:section_name/:graph_name' => [qw/sidebar get_complex/] => sub {
    my ( $self, $c )  = @_;
    my $result = $c->req->validator([
        'service_name' => {
            rule => [
                ['NOT_NULL', 'サービス名がありません'],
            ],
        },
        'section_name' => {
            rule => [
                ['NOT_NULL', 'セクション名がありません'],
            ],
        },
        'graph_name' => {
            rule => [
                ['NOT_NULL', 'グラフ名がありません'],
                [$self->check_uniq_complex($c->stash->{metrics}->{id}),'同じ名前のグラフがあります'],
            ],
        },
        'description' => {
            default => '',
            rule => [],
        },
        'stack' => {
            rule => [
                ['NOT_NULL', 'スタックの値がありません'],
                [['CHOICE',0,1], 'スタックの値が正しくありません'],
            ],
        },
        'sort' => {
            rule => [
                ['NOT_NULL', 'ソートの値がありません'],
                [['CHOICE',0..19], 'ソートの値が正しくありません'],
            ],
        },
        '@path-data' => {
            rule => [
                [['@SELECTED_NUM',1,100], 'データは100件までにしてください'],
                ['NOT_NULL','データが正しくありません'],
                ['NATURAL', 'データが正しくありません'],
            ],
        },
    ]);
    if ( $result->has_error ) {
        my $res = $c->render_json({
            error => 1,
            messages => $result->errors
        });
        return $res;
    }

    $self->data->update_complex(
        $c->stash->{metrics}->{id},
        $result->valid->mixed
    );

    my $row = $self->data->get_complex(
        $c->args->{service_name}, $c->args->{section_name}, $c->args->{graph_name},
    );

    $c->render_json({
        error => 0,
        metricses => [$row],
        location => $c->req->uri_for('/list/'.$result->valid('service_name').'/'.$result->valid('section_name'))->as_string,
    });
};


post '/delete_complex/:service_name/:section_name/:graph_name' => [qw/get_complex/] => sub {
    my ( $self, $c )  = @_;
    $self->data->delete_complex(
        $c->stash->{metrics}->{id},
    );
    $c->render_json({
        error => 0,
        location => $c->req->uri_for(
            '/list/'.$c->args->{service_name}.'/'.$c->args->{section_name})->as_string,
    });
};

my $display_csv = sub {
    my ( $self, $c )  = @_;
    my $result = $c->req->validator($metrics_validator);
    my ($from ,$to) = $self->calc_term( map {($_ =>  $result->valid($_))} qw/t from to period offset/);

    my $calculator = HRForecast::Calculator->new();
    my $rows = $calculator->calculate($self->data, $c->stash->{metrics}->{id}, $from ,$to, $result->valid('calculation'));

    my @result;
    push @result, [
        'Date',
        sprintf("/%s/%s/%s",map { $c->stash->{metrics}->{$_} } qw/service_name section_name graph_name/)
    ];
    foreach my $row ( @$rows ) {
        push @result, [
            $row->{datetime}->strftime('%Y/%m/%d %T'),
            $row->{number}
        ];
    }

    if ( $c->stash->{display_table} ) {
        return $c->render('table.tx', { table => \@result }); 
    }

    if ( $result->valid('d') ) {
        $c->res->header('Content-Disposition',
                        sprintf('attachment; filename="metrics_%s.csv"',$c->stash->{metrics}->{id}));
        $c->res->content_type('application/octet-stream');
    }
    else {
        $c->res->content_type('text/plain');
    }

    $c->res->body( join "\n", map { join ",", @$_ } @result );
    $c->res;
};

my $display_complex_csv =  sub {
    my ( $self, $c )  = @_;
    my $result = $c->req->validator($metrics_validator);
    my ($from ,$to) = $self->calc_term( map {($_ =>  $result->valid($_))} qw/t from to period offset/);

    my @data;
    my @id;
    if ( !$c->stash->{metrics} ) {
        my @complex = split /:/, $c->args->{complex};
        for my $id ( @complex ) {
            my $data = $self->data->get_by_id($id);
            next unless $data;
            push @data, $data;
            push @id, $data->{id};
        }
    }
    else {
        @data = @{$c->stash->{metrics}->{metricses}};
        @id = map { $_->{id} } @data;
    }

    my $calculator = HRForecast::Calculator->new();
    my $rows = $calculator->calculate($self->data, [ map { $_->{id} } @data ], $from, $to, $result->valid('calculation'));

    my %date_group;
    foreach my $row ( @$rows ) {
        my $datetime = $row->{datetime}->strftime('%Y%m%d%H%M%S');
        $date_group{$datetime} ||= {};
        $date_group{$datetime}->{$row->{metrics_id}} = $row->{number};
    }

    my @result;
    push @result, [
        'Date',
        map { '/'.$_->{service_name}.'/'.$_->{section_name}.'/'.$_->{graph_name} } @data
    ];
    
    foreach my $key ( sort keys %date_group ) {
        $key =~ m!^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})$!;
        my $datetime = sprintf "%s/%s/%s %s:%s:%s", $1, $2, $3, $4, $5, $6;

        push @result, [
            $datetime,
            map { exists $date_group{$key}->{$_} ? $date_group{$key}->{$_} : 0 } @id
        ];
    }

    if ( $c->stash->{display_table} ) {
        return $c->render('table.tx', { table => \@result }); 
    }


    if ( $result->valid('d') ) {
        $c->res->header('Content-Disposition',
                        sprintf('attachment; filename="metrics_%02d.csv"', int(rand(100)) ));
        $c->res->content_type('application/octet-stream');
    }
    else {
        $c->res->content_type('text/plain');
    }
    $c->res->body( join "\n", map { join ",", @$_ } @result );
    $c->res;    
};


get '/csv/:service_name/:section_name/:graph_name'
    => [qw/get_metrics/]
    => $display_csv;
get '/table/:service_name/:section_name/:graph_name'
    => [qw/get_metrics display_table/]
    => $display_csv;

get '/csv/:complex' => $display_complex_csv;
get '/csv_complex/:service_name/:section_name/:graph_name'
    => [qw/get_complex/]
    => $display_complex_csv;
get '/table/:complex' => [qw/display_table/] => $display_complex_csv;
get '/table_complex/:service_name/:section_name/:graph_name' 
    => [qw/get_complex display_table/] 
    => $display_complex_csv;


post '/api/:service_name/:section_name/:graph_name' => sub {
    my ( $self, $c )  = @_;
    my $result = $c->req->validator([
        'number' => {
            rule => [
                ['NOT_NULL','number is null'],
##                ['INT','number is not int']
            ],
        },
        'datetime' => {
            default => sub  { HTTP::Date::time2str(time) },
            rule => [
                [ sub { HTTP::Date::str2time($_[1]) } ,'datetime is not null']
            ],
        },
    ]);

    if ( $result->has_error ) {
        my $res = $c->render_json({
            error => 1,
            messages => $result->messages
        });
        $res->status(400);
        return $res;
    }

    my $ret = $self->data->update(
        $c->args->{service_name}, $c->args->{section_name}, $c->args->{graph_name},
        $result->valid('number'), HTTP::Date::str2time($result->valid('datetime'))
    );
    my $row = $self->data->get(
        $c->args->{service_name}, $c->args->{section_name}, $c->args->{graph_name},
    );

    $c->render_json({
        error => 0,
        metricses => [$row],
    });
};




1;

