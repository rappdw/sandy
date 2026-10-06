"""Host-side projection conformance; no image, runtime or AMAP dependency."""
import json
from pathlib import Path
import subprocess

import pytest

SCRIPT = Path(__file__).parents[1]/'sandy'
SOURCE = SCRIPT.read_text()
BLOCK = SOURCE[SOURCE.index('_sandy_fm_projector_js() {'):SOURCE.index('# Protected directories')]


def run(function, *args):
    return subprocess.run(['bash','-c', BLOCK+'\n'+function+' "$@"', '_', *map(str,args)],text=True,capture_output=True)


def manifest(tmp_path):
    feature=tmp_path/'f'; feature.mkdir()
    for name in ('work','work/results','work/ext','empty'):
        (feature/name).mkdir(exist_ok=True)
    doc={'schema':1,'sandboxes':{'include':['*']},'agents':{'include':['*']},
         'mounts':[{'name':'work','from':'work','mode':'rw'}],
         'submounts':[{'parent':'work','path':'results','from':'work/results'},
                      {'parent':'work','path':'ext','from':'empty','agents':['codex']}]}
    path=feature/'feature.json'; path.write_text(json.dumps(doc))
    return feature,path,doc


def test_node_and_jq_project_identically(tmp_path):
    feature,path,doc=manifest(tmp_path)
    for case in (doc, {**doc,'submounts':False}, {**doc,'submounts':[{'parent':None}]},
                 {**doc,'submounts':[{'parent':'work','path':'x','from':'empty','agents':['nope']}]},
                 {**doc,'submounts':[{'parent':'work','path':'x','from':'empty','mode':'rw'}]}):
        path.write_text(json.dumps(case))
        a=run('_sandy_fm_projector_js',path)
        js=subprocess.run(['node','-',str(path)],input=a.stdout,text=True,capture_output=True)
        jqscript=run('_sandy_fm_projector_jq',path).stdout
        jq=subprocess.run(['jq','-r','-f','/dev/stdin',str(path)],input=jqscript,text=True,capture_output=True)
        assert js.returncode==jq.returncode==0, (js.stderr,jq.stderr)
        assert js.stdout==jq.stdout


def test_parents_precede_selected_children(tmp_path):
    feature,path,doc=manifest(tmp_path)
    result=run('_sandy_fm_apply',tmp_path,'fixture','/workspace','codex',1)
    assert result.returncode==0,result.stdout+result.stderr
    mounts=[x for x in result.stdout.splitlines() if x.startswith('mount\t')]
    assert len(mounts)==3
    assert mounts[0].endswith('/.f/work\trw')
    assert mounts[1].endswith('/.f/work/results\tro')
    assert mounts[2].endswith('/.f/work/ext\tro')
    other=run('_sandy_fm_apply',tmp_path,'fixture','/workspace','claude',1)
    assert '/.f/work/ext\t' not in other.stdout


@pytest.mark.parametrize('child',['../escape','/absolute','results/../escape'])
def test_traversal_refuses_the_feature(tmp_path,child):
    feature,path,doc=manifest(tmp_path); doc['submounts'][0]['path']=child
    path.write_text(json.dumps(doc))
    assert run('_sandy_fm_apply',tmp_path,'fixture','/workspace','codex',1).returncode!=0


def test_symlink_and_alias_and_mixed_selection_fail(tmp_path):
    feature,path,doc=manifest(tmp_path)
    assert run('_sandy_fm_apply',tmp_path,'fixture','/workspace','codex,claude',1).returncode!=0
    doc['mounts'].append({'name':'alias','from':'work','mode':'rw'})
    path.write_text(json.dumps(doc))
    assert run('_sandy_fm_apply',tmp_path,'fixture','/workspace','codex',1).returncode!=0
    doc['mounts'].pop(); path.write_text(json.dumps(doc))
    (feature/'empty').rmdir(); (feature/'empty').symlink_to(feature/'work')
    assert run('_sandy_fm_apply',tmp_path,'fixture','/workspace','codex',1).returncode!=0


def test_read_only_file_submount_has_same_projection_contract(tmp_path):
    feature,path,doc=manifest(tmp_path)
    (feature/'protected.toml').write_text('trusted=true')
    doc['submounts']=[{'parent':'work','path':'config.toml','from':'protected.toml'}]
    path.write_text(json.dumps(doc))
    result=run('_sandy_fm_apply',tmp_path,'fixture','/workspace','codex',1)
    assert result.returncode==0,result.stdout+result.stderr
    assert 'protected.toml' in result.stdout and '/.f/work/config.toml\tro' in result.stdout


def test_overlapping_child_destinations_are_refused(tmp_path):
    feature,path,doc=manifest(tmp_path)
    doc['submounts'].append({'parent':'work','path':'results/nested','from':'empty'})
    path.write_text(json.dumps(doc))
    assert run('_sandy_fm_apply',tmp_path,'fixture','/workspace','codex',1).returncode!=0
