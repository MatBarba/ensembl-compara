=head1 LICENSE

  Copyright (c) 1999-2012 The European Bioinformatics Institute and
  Genome Research Limited.  All rights reserved.

  This software is distributed under a modified Apache license.
  For license details, please see

    http://www.ensembl.org/info/about/code_licence.html

=head1 CONTACT

  Please email comments or questions to the public Ensembl
  developers list at <dev@ensembl.org>.

  Questions may also be sent to the Ensembl help desk at
  <helpdesk@ensembl.org>.

=head1 NAME

Bio::EnsEMBL::Compara::RunnableDB::BlastAndParsePAF 

=head1 SYNOPSIS


=head1 DESCRIPTION

Run ncbi_blastp and parse the output into PeptideAlignFeature objects.
Store PeptideAlignFeature objects in the compara database
Supported keys:
    'blast_param' => <string>
        ncbi blastp parameters
eg "-num_alignments 20 -seg 'yes' -best_hit_overhang 0.2 -best_hit_score_edge 0.1 -use_sw_tback"
    'fasta_dir' => <directory path>
        Path to fasta files
    'mlss_id' => <number>
        Method link species set id for Pecan. Obligatory
    'genome_db_id' => <number>
        Species genome db id.
    'reuse_ss_id' => <number>
        Reuse species set id. Normally stored in the meta table. Obligatory.
    'do_transactions' => <0|1>
        Whether to do transactions. Default is no.


=cut

package Bio::EnsEMBL::Compara::RunnableDB::BlastAndParsePAF;

use strict;
use FileHandle;

use base ('Bio::EnsEMBL::Compara::RunnableDB::BaseRunnable');

use Bio::EnsEMBL::Analysis::RunnableDB::AlignmentFilter;
use Bio::EnsEMBL::Utils::Exception qw(throw warning info);
use Bio::EnsEMBL::Utils::SqlHelper;


sub param_defaults {
    return {
            'evalue_limit'  => 1e-5,
            'tophits'       => 20,
    };
}


#
# Fetch members and sequences from the database. 
#
sub load_members_from_db{
    my ($self) = @_;

    my $fasta_list;
    foreach my $member (@{$self->get_queries}) {
        my $member_id = $member->dbID;
        my $seq = $member->sequence;
        $seq=~ s/(.{72})/$1\n/g;
        chomp $seq;
        my $fasta_line = ">$member_id\n$seq\n";
        push @$fasta_list, $fasta_line;
    }

    return $fasta_list;
}


sub fetch_input {
    my $self = shift @_;

    my $fasta_list      = $self->load_members_from_db();

    if($self->debug) {
        print "Loaded ".scalar(@$fasta_list)." sequences\n";
    }

    $self->param('fasta_list', $fasta_list);

    my $reuse_ss_id = $self->param('reuse_ss_id')
                    or die "'reuse_ss_id' is an obligatory parameter dynamically set in 'meta' table by the pipeline - please investigate";

    my $reuse_ss = $self->compara_dba()->get_SpeciesSetAdaptor->fetch_by_dbID($reuse_ss_id);    # this method cannot fail at the moment, but in future it may

    my $reuse_ss_hash = {};

    if ($reuse_ss) {
        $reuse_ss_hash = { map { $_->dbID() => 1 } @{ $reuse_ss->genome_dbs() } };
    }
    $self->param('reuse_ss_hash', $reuse_ss_hash );

     # We get the list of genome_dbs to execute, then go one by one with this member

    my $mlss_id         = $self->param('mlss_id') or die "'mlss_id' is an obligatory parameter";
    my $mlss            = $self->compara_dba()->get_MethodLinkSpeciesSetAdaptor->fetch_by_dbID($mlss_id) or die "Could not fetch mlss with dbID=$mlss_id";
    my $species_set     = $mlss->species_set_obj->genome_dbs;

    my $genome_db_list;

    #If reusing this genome_db, only need to blast against the 'fresh' genome_dbs
    if ($reuse_ss_hash->{$self->param('genome_db_id')}) {
        foreach my $gdb (@$species_set) {
            if (!$reuse_ss_hash->{$gdb->dbID}) {
                push @$genome_db_list, $gdb;
            }
        }
    } else {
        #Using 'fresh' genome_db therefore must blast against everything
        $genome_db_list  = $species_set;
    }

    # If we restrict the search to one species at a time
    if ($self->param('target_genome_db_id')) {
        $genome_db_list = [grep {$_->dbID eq $self->param('target_genome_db_id')} @$genome_db_list];
    }

    print STDERR "Found ", scalar(@$genome_db_list), " genomes to blast this member against.\n" if ($self->debug);
    $self->param('genome_db_list', $genome_db_list);

}

sub parse_blast_table_into_paf {
    my ($self, $filename, $qgenome_db_id, $hgenome_db_id) = @_;

    my $debug                   = $self->debug() || $self->param('debug') || 0;

    my $features;

    open(BLASTTABLE, "<$filename") || die "Could not open the blast table file '$filename'";
    
    print "blast $qgenome_db_id $hgenome_db_id $filename\n" if $debug;

    while(my $line = <BLASTTABLE>) {

        unless ($line =~ /^#/) {
            my ($qmember_id, $hmember_id, $evalue, $score, $nident,$pident, $qstart, $qend, $hstart,$hend, $length, $positive, $ppos, $qseq, $sseq ) = split(/\s+/, $line);

            my $cigar_line;
            unless ($self->param('no_cigars')) {
                my $cigar_line1 = '';
                while($qseq=~/(?:\b|^)(.)(.*?)(?:\b|$)/g) {
                    $cigar_line1 .= ($2 ? length($2)+1 : '').(($1 eq '-') ? 'D' : 'M');
                }
                my $cigar_line2 = '';
                while($sseq=~/(?:\b|^)(.)(.*?)(?:\b|$)/g) {
                    $cigar_line2 .= ($2 ? length($2)+1 : '').(($1 eq '-') ? 'D' : 'M');
                }
                $cigar_line = Bio::EnsEMBL::Analysis::RunnableDB::AlignmentFilter->daf_cigar_from_compara_cigars($cigar_line1, $cigar_line2);
            }

            my $feature = {
                    qmember_id        => $qmember_id,
                    hmember_id        => $hmember_id,
                    qgenome_db_id     => $qgenome_db_id,
                    hgenome_db_id     => $hgenome_db_id,
                    perc_ident        => $pident,
                    score             => $score,
                    evalue            => $evalue,
                    qstart            => $qstart,
                    qend              => $qend,
                    hstart            => $hstart,
                    hend              => $hend,
                    length            => $length,
                    perc_ident        => $pident,
                    identical_matches => $nident,
                    positive          => $positive,
                    perc_pos          => $ppos,
                    cigar_line        => $cigar_line,
            };

            print "feature query $qgenome_db_id $qmember_id hit $hgenome_db_id $hmember_id $hmember_id $qstart $qend $hstart $hend $length $nident $positive\n" if $debug;
            push @{$features->{$qmember_id}}, $feature;
        }
    }
    close BLASTTABLE;
    if (!defined $features) {
        return $features;
    }

    #group together by qmember_id and rank the hits
    foreach my $qmember_id (keys %$features) {
        my $qfeatures = $features->{$qmember_id};
        @$qfeatures = sort sort_by_score_evalue_and_pid @$qfeatures;
        my $rank=1;
        my $prevPaf = undef;
        foreach my $paf (@$qfeatures) {
            $rank++ if($prevPaf and !pafs_equal($prevPaf, $paf));
            $paf->{hit_rank} = $rank;
            $prevPaf = $paf;
        }
    }
    return $features;
}

sub sort_by_score_evalue_and_pid {
  $b->{score} <=> $a->{score} ||
    $a->{evalue} <=> $b->{evalue} ||
      $b->{perc_ident} <=> $a->{perc_ident} ||
        $b->{perc_pos} <=> $a->{perc_pos};
}

sub pafs_equal {
  my ($paf1, $paf2) = @_;
  return 0 unless($paf1 and $paf2);
  return 1 if(($paf1->{score} == $paf2->{score}) and
              ($paf1->{evalue} == $paf2->{evalue}) and
              ($paf1->{perc_ident} == $paf2->{perc_ident}) and
              ($paf1->{perc_pos} == $paf2->{perc_pos}));
  return 0;
}

sub run {
    my $self = shift @_;

    my $fasta_list              = $self->param('fasta_list'); # set by fetch_input()
    my $debug                   = $self->debug() || $self->param('debug') || 0;

    unless(scalar(@$fasta_list)) { # if we have no more work to do just exit gracefully
        if($debug) {
            warn "No work to do, exiting\n";
        }
        return;
    }
    my $reuse_db          = $self->param('reuse_db');   # if this parameter is an empty string, there will be no reuse

    my $reuse_ss_hash     = $self->param('reuse_ss_hash');
    my $reuse_this_member = $reuse_ss_hash->{$self->param('genome_db_id')};

    my $blastdb_dir             = $self->param('fasta_dir');

    my $blast_bin_dir           = $self->param('blast_bin_dir') || die;
    my $blast_params            = $self->param('blast_params')  || '';  # no parameters to C++ binary means having composition stats on and -seg masking off
    my $evalue_limit            = $self->param('evalue_limit');
    my $tophits                 = $self->param('tophits');

    my $worker_temp_directory   = $self->worker_temp_directory;

    my $blast_infile  = $worker_temp_directory . 'blast.in.'.$$;     # only for debugging
    my $blast_outfile = $worker_temp_directory . 'blast.out.'.$$;    # looks like inevitable evil (tried many hairy alternatives and failed)

    if($debug) {
        open(FASTA, ">$blast_infile") || die "Could not open '$blast_infile' for writing";
        print FASTA @$fasta_list;
        close FASTA;
    }

    $self->compara_dba->dbc->disconnect_when_inactive(1); 

    my $cross_pafs = [];
    #my %cross_pafs = ();
    foreach my $genome_db (@{$self->param('genome_db_list')}) {
        my $fastafile = $genome_db->name() . '_' . $genome_db->assembly() . '.fasta';
        $fastafile =~ s/\s+/_/g;    # replace whitespace with '_' characters
            $fastafile =~ s/\/\//\//g;  # converts any // in path to /
            my $cross_genome_dbfile = $blastdb_dir . '/' . $fastafile;   # we are always interested in the 'foreign' genome's fasta file, not the member's

            #Don't blast against self
            unless ($genome_db->dbID == $self->param('genome_db_id')) {

                #Run blastp
                my $cig_cmd = $self->param('no_cigars') ? '' : 'qseq sseq';
                my $cmd = "${blast_bin_dir}/blastp -db $cross_genome_dbfile $blast_params -evalue $evalue_limit -max_target_seqs $tophits -out $blast_outfile -outfmt '7 qacc sacc evalue score nident pident qstart qend sstart send length positive ppos $cig_cmd'";
                if($debug) {
                    warn "CMD:\t$cmd\n";
                }
                my $start_time = time();
                open( BLAST, "| $cmd") || die qq{could not execute "$cmd", returned error code: $!};
                print BLAST @$fasta_list;
                close BLAST;

                print "Time for blast " . (time() - $start_time) . "\n";

                my $features = $self->parse_blast_table_into_paf($blast_outfile, $self->param('genome_db_id'), $genome_db->dbID);
                if (defined $features) {
                    foreach my $qmember_id (keys %$features) {
                        my $qfeatures = $features->{$qmember_id};
                        push @$cross_pafs, @$qfeatures;
                        #push @{$cross_pafs{$genome_db->dbID}}, $feature;
                    }
                }
                unless($debug) {
                    unlink $blast_outfile;
                }
            }
    }
    $self->compara_dba->dbc->disconnect_when_inactive(0); 

    $self->param('cross_pafs', $cross_pafs);
    #$self->param('cross_pafs', \%cross_pafs);
}

sub write_output {
    my ($self) = @_;

    if ($self->param('do_transactions')) {
        my $compara_conn = $self->compara_dba->dbc;

        my $compara_helper = Bio::EnsEMBL::Utils::SqlHelper->new(-DB_CONNECTION => $compara_conn);
        $compara_helper->transaction(-CALLBACK => sub {
                $self->_write_output;
                });
    } else {
        $self->_write_output;
    }

}


sub _write_output {
    my $self = shift @_;

    my $cross_pafs = $self->param('cross_pafs');
    #foreach my $genome_db_id (keys %$cross_pafs) {
    #    $self->compara_dba->get_PeptideAlignFeatureAdaptor->store(@{$cross_pafs->{$genome_db_id}});
    #}
    print "numbers pafs " . scalar(@$cross_pafs) . "\n";
    foreach my $feature (@$cross_pafs) {
        my $peptide_table = $self->get_table_name_from_dbID($feature->{qgenome_db_id});

        #AWFUL HACK to insert into the peptide_align_feature table but without going through the API. Only fill in
        #some the of fields
        my $sql = "INSERT INTO $peptide_table (qmember_id, hmember_id, qgenome_db_id, hgenome_db_id, qstart, qend, hstart, hend, score, evalue, hit_rank,identical_matches, perc_ident,align_length,positive_matches, perc_pos, cigar_line) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?, ?,?,?)";
        my $sth = $self->compara_dba->dbc->prepare( $sql );

        #print "INSERT INTO $peptide_table (qmember_id, hmember_id, qgenome_db_id, hgenome_db_id, qstart, qend, hstart, hend, score, evalue, hit_rank,identical_matches, perc_ident,align_length,positive_matches, perc_pos) VALUES ('" . $feature->{qmember_id} , "','" . $feature->{hmember_id} . "'," . $feature->{qgenome_db_id} . "," . $feature->{hgenome_db_id} . "," . $feature->{qstart} . "," . $feature->{qend} . "," . $feature->{hstart} . "," . $feature->{hend} . "," . $feature->{score} . "," . $feature->{evalue} . "," . $feature->{hit_rank} . "," . $feature->{identical_matches} . "," . $feature->{perc_ident} . "," . $feature->{length} . "," . $feature->{positive} . "," . $feature->{perc_pos} . "\n";

        $sth->execute($feature->{qmember_id},
                $feature->{hmember_id},
                $feature->{qgenome_db_id},
                $feature->{hgenome_db_id},
                $feature->{qstart},
                $feature->{qend},
                $feature->{hstart},
                $feature->{hend},
                $feature->{score},
                $feature->{evalue},
                $feature->{hit_rank},
                $feature->{identical_matches},
                $feature->{perc_ident},
                $feature->{length},
                $feature->{positive},
                $feature->{perc_pos},
                $feature->{cigar_line},
                );
    }
}

sub get_table_name_from_dbID {
    my ($self, $gdb_id) = @_;
    my $table_name = "peptide_align_feature";

    my $gdba = $self->compara_dba->get_GenomeDBAdaptor;
    my $gdb = $gdba->fetch_by_dbID($gdb_id);
    return $table_name if (!$gdb);

    $table_name .= "_" . lc($gdb->name) . "_" . $gdb_id;
    $table_name =~ s/ /_/g;

    return $table_name;
}


1;

