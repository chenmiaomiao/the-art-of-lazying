# Lazy-Care: Smart File Management Tools

Welcome to `Lazy-Care`, a sub-module of the `the-art-of-lazying` project. This suite of Unix shell scripts is designed to provide a safer, more intentional approach to file management. The `Lazy-Care` toolkit includes `saferm`, `unrm`, and `removeitanyway`, offering a robust solution to handle files thoughtfully and safely.

## Project Structure

```
the-art-of-lazying/
│
├── books/
├── code/
│   └── ...
├── examples/
├── scripts/
│   └── lazy-care/
│       ├── saferm.sh
│       ├── unrm.sh
│       └── removeitanyway.sh
├── vlogs/
└── README.md
```

## Installation Instructions:


1. Clone the repository:
   ```bash
   git clone https://github.com/lachlanchen/the-art-of-lazying.git
   ```
2. Navigate to the `lazy-care` directory:
   ```bash
   cd the-art-of-lazying/scripts/lazy-care/SafeShell
   ```
3. Add the functions to your shell configuration file (`.bashrc` or `.zshrc`):
   ```bash
   cat safeshell_functions.sh >> ~/.bashrc  # or ~/.zshrc
   ```
4. Reload your shell configuration:
   ```bash
   source ~/.bashrc  # or ~/.zshrc
   ```

## Usage

- **saferm**: Replace your traditional `rm` command with `saferm` to move files to a safe trash directory.
  ```bash
  saferm /path/to/file_or_directory
  ```
- **unrm**: Restore files from the trash directory to their original location.
  ```bash
  unrm /path/to/file_or_directory
  ```
- **removeitanyway**: Permanently delete files with a confirmation step.
  ```bash
  removeitanyway /path/to/file_or_directory
  ```
## Contributing

Contributions are what make the open-source community such an amazing place to learn, inspire, and create. We welcome any contributions that enhance the functionality and usability of `Lazy-Care`.

Please adhere to the standard GitHub contribution protocols:

1. Fork the Project
2. Create your Feature Branch (`git checkout -b feature/AmazingFeature`)
3. Commit your Changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the Branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

## License

This project is licensed under the MIT License - see the [LICENSE](https://lazying.art/LICENSE) file for details.

## Contact

Lachlan Chen - lachlan@lazying.art

Project Link: https://github.com/lachlanchen/the-art-of-lazying
