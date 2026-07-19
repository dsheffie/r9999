#!/usr/bin/python3

import glob
import os
import subprocess
import re

def main():
    svs = glob.glob('*.sv')
    if not os.path.isdir('verilog'):
        os.mkdir('verilog')

    # Extra sv2v -D defines, space/comma separated (e.g. henry's gen_mipscore.sh sets
    # SV2V_DEFINES=ENABLE_DEBUG_WATCHPOINT so the r9999 submodule machine.vh can stay ==
    # main -- the henry-only build knobs are injected here, not committed in the header).
    extra_defines = ['-D=' + d for d in os.environ.get('SV2V_DEFINES', '').replace(',', ' ').split()]

    outputs = []
    modules = set()
    for sv in svs:
        module_names = []
        with open(sv, 'r') as in_:
            for line in in_:
                m = re.search(r'module\s+(\w+)(#?)(\s+)?\(', line)
                if m == None:
                    continue
                g = m.groups()
                module_names.append(g[0])

        for module in module_names:
            if module in modules:
                print('huh already seen %s, source %s' % (module, sv))
            else:
                modules.add(module)
        
        r = sv.split('.sv')[0]
        v = r+'.v'
        cmd = ['sv2v', sv, '--write=verilog/'+v, '-D=FPGA'] + extra_defines
        outputs.append('verilog/' + v)
        subprocess.run(cmd)

    with open('mipscore.v', 'w') as o:
        for output in outputs:
            with open(output, 'r') as in_:
                for line in in_:
                    o.write('%s' % line)
                o.write('\n\n')

if __name__ == "__main__":
    main()
