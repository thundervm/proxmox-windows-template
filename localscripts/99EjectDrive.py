import os
import shutil
import ctypes
import sys

def remove_drive():
    drive_letter = os.popen('wmic logicaldisk where VolumeName="config-2" get Caption | findstr /I ":"').read()
    if drive_letter:
        print('powershell "(new-object -COM Shell.Application).NameSpace(17).ParseName(\'' + drive_letter + '\').InvokeVerb(\'Eject\')"')

remove_drive()
sys.exit(0)