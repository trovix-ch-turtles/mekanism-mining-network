const fs = require('fs');
const axios = require('axios');
const FormData = require('form-data');

async function uploadToPastebin() {
  try {
    // Read the installer.lua file
    const fileContent = fs.readFileSync('installer.lua', 'utf8');
    
    // Create form data for the API request
    const formData = new FormData();
    formData.append('api_dev_key', process.env.PASTEBIN_API_KEY);
    formData.append('api_user_key', process.env.PASTEBIN_USER_KEY);
    formData.append('api_option', 'paste');
    formData.append('api_paste_name', 'Mekanism Mining Network Installer');
    formData.append('api_paste_code', fileContent);
    formData.append('api_paste_format', 'lua');
    formData.append('api_paste_private', '0'); // Public paste
    formData.append('api_paste_expire_date', 'N'); // Never expire
    
    // Check if we have an existing paste to replace
    const existingPasteKey = 'mekanism_mining'; // The paste name you want to use
    
    if (existingPasteKey) {
      // If we have an existing paste, use 'api_paste_key' to replace it
      formData.append('api_paste_key', existingPasteKey);
    }
    
    // Make the API request to Pastebin
    const response = await axios.post('https://pastebin.com/api/api_post.php', formData, {
      headers: formData.getHeaders()
    });
    
    console.log('Upload successful!');
    console.log('Paste URL:', response.data);
  } catch (error) {
    console.error('Error uploading to Pastebin:', error.response?.data || error.message);
    process.exit(1);
  }
}

uploadToPastebin();