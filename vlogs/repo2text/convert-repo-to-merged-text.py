import os

def merge_py_files_by_directory(source_directory, target_directory):
    for subdir, dirs, files in os.walk(source_directory):
        py_files = [f for f in files if f.endswith('.py')]
        if py_files:
            relative_path = os.path.relpath(subdir, start=source_directory)
            new_filename = relative_path.replace(os.sep, '_') + '.txt'
            target_file_path = os.path.join(target_directory, new_filename)

            # Create target directory if it doesn't exist
            os.makedirs(target_directory, exist_ok=True)

            with open(target_file_path, "w") as outfile:
                for file in py_files:
                    file_path = os.path.join(subdir, file)
                    outfile.write(f"{'=' * 20}\n")
                    outfile.write(f"File: {file_path}\n")
                    outfile.write(f"{'=' * 20}\n\n")
                    with open(file_path, "r") as infile:
                        outfile.write(infile.read())
                        outfile.write("\n\n")

# Path to the diffractsim directory
source_directory = 'diffraction'

# Path to the target directory
target_directory = 'merged_py_files'

# Merging .py files by directory
merge_py_files_by_directory(source_directory, target_directory)

